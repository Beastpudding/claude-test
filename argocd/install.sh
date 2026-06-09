#!/usr/bin/env bash
# Argo CD EKS 설치 (Helm) + Cognito OIDC + internet-facing NLB + CloudFront.
#
# 흐름:
#   1. .env 로드
#   2. Cognito App Client (argocd용, Confidential)
#   3. Helm: argo/argo-cd 차트 설치 (namespace=argocd, values.yaml 렌더)
#   4. argocd-secret에 oidc.cognito.clientSecret 주입
#   5. server Service의 NLB DNS 캡처
#   6. CloudFront 분배 생성 + Cognito callback 갱신
#   7. (재실행 시) 정식 ARGOCD_URL 반영
#
# 사용:
#   ./argocd/install.sh           # 신규 또는 멱등
#   ./argocd/install.sh teardown  # 리소스 일괄 삭제 (CloudFront/Cognito 제외)

set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then echo "ERROR: .env 없음" >&2; exit 1; fi
set -o allexport; . ./.env; set +o allexport

: "${AWS_REGION:?}"
: "${COGNITO_USER_POOL_ID:?}"
: "${JUPYTERHUB_ADMIN:?}"

ARGOCD_NAME="${ARGOCD_NAME:-argocd-kbdev}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.7.10}"   # argo-cd Helm chart

# ── teardown ────────────────────────────────────────────────────
if [ "${1:-}" = "teardown" ]; then
    echo "=== Argo CD 제거 ==="
    helm uninstall argocd -n "$ARGOCD_NAMESPACE" 2>/dev/null || true
    kubectl delete namespace "$ARGOCD_NAMESPACE" --ignore-not-found
    echo "(Cognito App Client / CloudFront은 콘솔에서 수동 삭제)"
    exit 0
fi

# ── 1. Cognito App Client ───────────────────────────────────────
echo "=== Step 1: Cognito App Client ==="
ARGOCD_CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "$COGNITO_USER_POOL_ID" --region "$AWS_REGION" \
    --query "UserPoolClients[?ClientName=='$ARGOCD_NAME'].ClientId | [0]" --output text 2>/dev/null || true)
TEMP_CB="${ARGOCD_URL:-https://placeholder.cloudfront.net}/auth/callback"

if [ -z "$ARGOCD_CLIENT_ID" ] || [ "$ARGOCD_CLIENT_ID" = "None" ]; then
    OUT=$(aws cognito-idp create-user-pool-client --region "$AWS_REGION" \
        --user-pool-id "$COGNITO_USER_POOL_ID" \
        --client-name "$ARGOCD_NAME" \
        --generate-secret \
        --allowed-o-auth-flows code \
        --allowed-o-auth-scopes openid email profile \
        --allowed-o-auth-flows-user-pool-client \
        --supported-identity-providers COGNITO \
        --callback-urls "$TEMP_CB" \
        --logout-urls "${ARGOCD_URL:-https://placeholder.cloudfront.net}/" \
        --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH \
        --output json)
    ARGOCD_CLIENT_ID=$(echo "$OUT" | jq -r '.UserPoolClient.ClientId')
    ARGOCD_CLIENT_SECRET=$(echo "$OUT" | jq -r '.UserPoolClient.ClientSecret')
    echo "  신규: $ARGOCD_CLIENT_ID"
else
    ARGOCD_CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client --region "$AWS_REGION" \
        --user-pool-id "$COGNITO_USER_POOL_ID" --client-id "$ARGOCD_CLIENT_ID" \
        --query 'UserPoolClient.ClientSecret' --output text)
    echo "  기존: $ARGOCD_CLIENT_ID"
fi

# ── 2. Helm install ─────────────────────────────────────────────
echo ""
echo "=== Step 2: Helm install ==="
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo >/dev/null

COGNITO_ISSUER="https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}"
ARGOCD_DOMAIN="${ARGOCD_URL#https://}"
ARGOCD_DOMAIN="${ARGOCD_DOMAIN:-placeholder.cloudfront.net}"

VALUES_RENDERED=$(sed \
    -e "s|__ARGOCD_DOMAIN__|$ARGOCD_DOMAIN|g" \
    -e "s|__COGNITO_ISSUER__|$COGNITO_ISSUER|g" \
    -e "s|__COGNITO_CLIENT_ID__|$ARGOCD_CLIENT_ID|g" \
    -e "s|__ARGOCD_ADMIN__|$JUPYTERHUB_ADMIN|g" \
    argocd/values.yaml)

echo "$VALUES_RENDERED" > /tmp/argocd-values-rendered.yaml

helm upgrade --install argocd argo/argo-cd \
    --namespace "$ARGOCD_NAMESPACE" --create-namespace \
    --version "$ARGOCD_CHART_VERSION" \
    --values /tmp/argocd-values-rendered.yaml \
    --wait --timeout 10m 2>&1 | tail -10

# ── 3. argocd-secret에 OIDC client secret 주입 ──────────────────
echo ""
echo "=== Step 3: argocd-secret에 clientSecret 주입 ==="
kubectl -n "$ARGOCD_NAMESPACE" patch secret argocd-secret \
    --type merge \
    -p "{\"stringData\":{\"oidc.cognito.clientSecret\":\"$ARGOCD_CLIENT_SECRET\"}}"

# argocd-server 재기동해서 OIDC config 다시 로드
kubectl -n "$ARGOCD_NAMESPACE" rollout restart deployment/argocd-server
kubectl -n "$ARGOCD_NAMESPACE" rollout status deployment/argocd-server --timeout 5m

# ── 4. NLB DNS 캡처 ────────────────────────────────────────────
echo ""
echo "=== Step 4: NLB DNS ==="
for i in $(seq 1 30); do
    NLB_DNS=$(kubectl -n "$ARGOCD_NAMESPACE" get svc argocd-server \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [ -n "$NLB_DNS" ]; then break; fi
    sleep 10
done
echo "  NLB DNS: ${NLB_DNS:-(미할당)}"

# ── 5. admin 초기 비번 (Cognito 장애 fallback) ──────────────────
ADMIN_PWD=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(이미 변경됨)")

cat <<EOF

═══════════════════════════════════════════════════════════════════
✅ Argo CD 1차 설치 완료

다음 수동 단계:
  1. CloudFront 분배 생성 (Jenkins/Harbor와 동일):
     - Origin: $NLB_DNS (http-only, 80)
     - Cache: CachingDisabled
     - Origin request: AllViewer (Host + Auth 헤더 전달 필수)
  2. .env 추가:
     ARGOCD_URL=https://<distribution>.cloudfront.net
     ARGOCD_COGNITO_CLIENT_ID=$ARGOCD_CLIENT_ID
     ARGOCD_COGNITO_CLIENT_SECRET=$ARGOCD_CLIENT_SECRET
     ARGOCD_NLB_DNS=$NLB_DNS
  3. Cognito callback 갱신:
     aws cognito-idp update-user-pool-client \\
       --user-pool-id $COGNITO_USER_POOL_ID \\
       --client-id $ARGOCD_CLIENT_ID \\
       --callback-urls https://<distribution>.cloudfront.net/auth/callback \\
       --logout-urls https://<distribution>.cloudfront.net/
  4. ./argocd/install.sh 재실행 → values.yaml의 ARGOCD_DOMAIN/url 정식값 반영
  5. ./deploy.sh → launcher에 Argo CD 카드 등장

Argo CD admin (Cognito 장애 시 fallback):
  username: admin
  password: $ADMIN_PWD

═══════════════════════════════════════════════════════════════════
EOF
