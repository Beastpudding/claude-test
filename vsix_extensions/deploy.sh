#!/bin/bash
set -euo pipefail

# ============================================================
# JupyterHub EKS 배포 스크립트
# 사용법: ./deploy.sh
#
# 사전 조건:
#   - aws CLI, docker, helm, kubectl 설치
#   - aws configure (또는 EC2 IAM 역할) 설정
#   - EKS 클러스터 생성 완료
#   - .env 파일에 아래 변수 설정
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f ".env" ]; then
    echo "⚠️  .env 파일이 없습니다. .env.example에서 복사합니다..."
    cp .env.example .env
    echo "❌ .env 파일을 열어 AWS_ACCOUNT_ID, EKS_CLUSTER_NAME 등을 설정하세요."
    exit 1
fi

set -o allexport; source .env; set +o allexport

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null)}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:?EKS_CLUSTER_NAME 환경변수를 .env에 설정하세요}"
NAMESPACE="${NAMESPACE:-jupyterhub}"
HELM_RELEASE="${HELM_RELEASE:-jupyterhub}"
CODE_VERSION="${CODE_VERSION:-4.95.3}"

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# TARGET_ARCH: EKS 노드 아키텍처 (로컬 빌드 머신과 다를 수 있음)
# .env에서 명시적으로 지정하거나, 기본값 amd64 사용 (t3/t3a/m5 등 일반 EKS 노드)
TARGET_ARCH="${TARGET_ARCH:-amd64}"
ARCH="$TARGET_ARCH"

SSO_START_URL="${SSO_START_URL:-}"
SSO_CLIENT_ID="${SSO_CLIENT_ID:-}"
SSO_CLIENT_SECRET="${SSO_CLIENT_SECRET:-}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-}"

echo "============================================================"
echo " JupyterHub EKS 배포"
echo " Region:  $AWS_REGION"
echo " Account: $AWS_ACCOUNT_ID"
echo " Cluster: $EKS_CLUSTER_NAME"
echo " Arch:    $ARCH"
echo " SSO:     ${SSO_START_URL:-비활성 (NativeAuthenticator 사용)}"
echo "============================================================"

# ============================================================
# 1. 사전 준비 확인
# ============================================================
echo ""
echo "[1/5] 사전 준비 확인..."

for cmd in aws docker helm kubectl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ $cmd 가 설치되어 있지 않습니다."
        exit 1
    fi
done
echo "  ✅ aws / docker / helm / kubectl 확인 완료"

# ============================================================
# 2. ECR 로그인 및 저장소 생성
# ============================================================
echo ""
echo "[2/5] ECR 준비..."

aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"

for repo in codeserver-kbdev jupyterhub-hub; do
    if ! aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$repo" &>/dev/null; then
        echo "  📦 ECR 저장소 생성: $repo"
        aws ecr create-repository --region "$AWS_REGION" --repository-name "$repo" > /dev/null
    fi
done
echo "  ✅ ECR 준비 완료"

# ============================================================
# 3. Docker 이미지 빌드 및 푸시
# ============================================================
echo ""
echo "[3/5] Docker 이미지 빌드 및 푸시..."

DEB_FILE="code-server_${CODE_VERSION}_${ARCH}.deb"
if [ ! -f "$DEB_FILE" ]; then
    echo "  ⬇️  code-server .deb 다운로드 중..."
    curl -fOL "https://github.com/coder/code-server/releases/download/v${CODE_VERSION}/${DEB_FILE}"
fi
echo "  ✅ $DEB_FILE 확인 완료"

echo "  🔨 singleuser 이미지 빌드 중..."
docker build \
    -f Dockerfile.codeserver \
    -t "${ECR_REGISTRY}/codeserver-kbdev:latest" \
    --build-arg CODE_VERSION="${CODE_VERSION}" \
    --build-arg TARGETARCH="${ARCH}" \
    --platform "linux/${ARCH}" \
    .
docker push "${ECR_REGISTRY}/codeserver-kbdev:latest"
echo "  ✅ codeserver-kbdev 푸시 완료"

echo "  🔨 hub 이미지 빌드 중..."
docker build \
    -f Dockerfile.jupyterhub \
    -t "${ECR_REGISTRY}/jupyterhub-hub:latest" \
    --platform "linux/${ARCH}" \
    .
docker push "${ECR_REGISTRY}/jupyterhub-hub:latest"
echo "  ✅ jupyterhub-hub 푸시 완료"

# ============================================================
# 4. Kubernetes / Helm 준비
# ============================================================
echo ""
echo "[4/5] Kubernetes 설정..."

aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# EKS 노드의 IMDS hop limit이 1이면 파드에서 IMDS에 접근 불가 (EBS CSI 등 오작동).
# 새 노드 그룹 생성 시 hop limit=1이 기본값이므로 2로 강제 설정.
_fix_imds_hop_limit() {
    local node_ips
    node_ips=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    for ip in $node_ips; do
        instance_id=$(aws ec2 describe-instances \
            --filters "Name=private-ip-address,Values=${ip}" \
            --query "Reservations[0].Instances[0].InstanceId" \
            --output text --region "$AWS_REGION" 2>/dev/null)
        [ -z "$instance_id" ] || [ "$instance_id" = "None" ] && continue
        current=$(aws ec2 describe-instances --instance-ids "$instance_id" --region "$AWS_REGION" \
            --query "Reservations[0].Instances[0].MetadataOptions.HttpPutResponseHopLimit" \
            --output text 2>/dev/null)
        if [ "${current:-1}" -lt 2 ] 2>/dev/null; then
            aws ec2 modify-instance-metadata-options \
                --instance-id "$instance_id" \
                --http-put-response-hop-limit 2 \
                --region "$AWS_REGION" > /dev/null
            echo "  📌 IMDS hop limit 2로 설정: $instance_id ($ip)"
        fi
    done
}
echo "  🔧 IMDS hop limit 확인 중..."
_fix_imds_hop_limit
echo "  ✅ IMDS 설정 완료"

helm repo add jupyterhub https://hub.jupyter.org/helm-chart/ 2>/dev/null || true
helm repo update
echo "  ✅ kubeconfig 및 Helm repo 업데이트 완료"

# ============================================================
# 4.1. IRSA — LiteLLM Bedrock 접근 권한
# ============================================================
echo ""
echo "[4.1] LiteLLM IRSA 설정..."

LITELLM_SA="litellm"
LITELLM_ROLE="JupyterHubLiteLLM-${EKS_CLUSTER_NAME}"
LITELLM_POLICY="JupyterHubLiteLLMBedrock-${EKS_CLUSTER_NAME}"

OIDC_ISSUER=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" \
    --query "cluster.identity.oidc.issuer" --output text)
OIDC_PROVIDER="${OIDC_ISSUER#https://}"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"

# Register OIDC provider in IAM if not already done
if ! aws iam get-open-id-connect-provider \
        --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" &>/dev/null; then
    echo "  📌 IAM OIDC 프로바이더 등록 중..."
    OIDC_HOST="${OIDC_PROVIDER%%/*}"
    THUMBPRINT=$(echo | openssl s_client \
        -connect "${OIDC_HOST}:443" -servername "${OIDC_HOST}" 2>/dev/null \
        | openssl x509 -fingerprint -noout -sha1 2>/dev/null \
        | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')
    aws iam create-open-id-connect-provider \
        --url "${OIDC_ISSUER}" \
        --client-id-list sts.amazonaws.com \
        --thumbprint-list "${THUMBPRINT}" > /dev/null
    echo "  ✅ OIDC 프로바이더 등록 완료"
else
    echo "  ✅ 기존 OIDC 프로바이더 재사용"
fi

# Create Bedrock IAM policy (idempotent)
POLICY_ARN=$(aws iam list-policies --scope Local \
    --query "Policies[?PolicyName=='${LITELLM_POLICY}'].Arn" \
    --output text 2>/dev/null)
if [ -z "$POLICY_ARN" ]; then
    echo "  📌 Bedrock IAM 정책 생성 중..."
    POLICY_ARN=$(aws iam create-policy \
        --policy-name "$LITELLM_POLICY" \
        --policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": [
                    "bedrock:InvokeModel",
                    "bedrock:InvokeModelWithResponseStream"
                ],
                "Resource": "*"
            }]
        }' \
        --query 'Policy.Arn' --output text)
    echo "  ✅ IAM 정책 생성: $POLICY_ARN"
else
    echo "  ✅ 기존 IAM 정책 재사용: $POLICY_ARN"
fi

# Create IRSA role with OIDC trust policy (idempotent)
if ! aws iam get-role --role-name "$LITELLM_ROLE" &>/dev/null; then
    echo "  📌 IRSA 역할 생성 중..."
    aws iam create-role \
        --role-name "$LITELLM_ROLE" \
        --assume-role-policy-document "{
            \"Version\": \"2012-10-17\",
            \"Statement\": [{
                \"Effect\": \"Allow\",
                \"Principal\": {\"Federated\": \"${OIDC_PROVIDER_ARN}\"},
                \"Action\": \"sts:AssumeRoleWithWebIdentity\",
                \"Condition\": {
                    \"StringEquals\": {
                        \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:${NAMESPACE}:${LITELLM_SA}\",
                        \"${OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"
                    }
                }
            }]
        }" > /dev/null
    aws iam attach-role-policy \
        --role-name "$LITELLM_ROLE" \
        --policy-arn "$POLICY_ARN"
    echo "  ✅ IRSA 역할 생성: $LITELLM_ROLE"
else
    echo "  ✅ 기존 IRSA 역할 재사용: $LITELLM_ROLE"
fi
LITELLM_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${LITELLM_ROLE}"

# ============================================================
# 4.2. K8s 시크릿 — LiteLLM 마스터 키 / PostgreSQL / SSO 자격증명
# ============================================================
echo ""
echo "[4.2] K8s 시크릿 설정..."

# LiteLLM master key
if [ -z "$LITELLM_MASTER_KEY" ]; then
    LITELLM_MASTER_KEY="$(openssl rand -hex 24)"
fi
LITELLM_API_KEY="sk-${LITELLM_MASTER_KEY}"

if ! kubectl get secret litellm-secrets -n "$NAMESPACE" &>/dev/null; then
    kubectl create secret generic litellm-secrets \
        -n "$NAMESPACE" \
        --from-literal=master-key="${LITELLM_API_KEY}"
    echo "  ✅ litellm-secrets 생성 완료 (키: ${LITELLM_API_KEY:0:12}...)"
else
    echo "  ✅ 기존 litellm-secrets 재사용"
fi

# PostgreSQL credentials — generated once, reused on subsequent deploys
if ! kubectl get secret postgres-secrets -n "$NAMESPACE" &>/dev/null; then
    _PG_PASSWORD="$(openssl rand -hex 16)"
    kubectl create secret generic postgres-secrets \
        -n "$NAMESPACE" \
        --from-literal=password="${_PG_PASSWORD}" \
        --from-literal=database-url="postgresql://litellm:${_PG_PASSWORD}@postgres.${NAMESPACE}.svc.cluster.local:5432/litellm"
    echo "  ✅ postgres-secrets 생성 완료"
else
    echo "  ✅ 기존 postgres-secrets 재사용"
fi

# SSO secret — only created when all three vars are set
if [ -n "$SSO_START_URL" ] && [ -n "$SSO_CLIENT_ID" ] && [ -n "$SSO_CLIENT_SECRET" ]; then
    kubectl delete secret jupyterhub-sso -n "$NAMESPACE" 2>/dev/null || true
    kubectl create secret generic jupyterhub-sso \
        -n "$NAMESPACE" \
        --from-literal=sso-start-url="$SSO_START_URL" \
        --from-literal=client-id="$SSO_CLIENT_ID" \
        --from-literal=client-secret="$SSO_CLIENT_SECRET"
    echo "  ✅ jupyterhub-sso 시크릿 생성 완료"
    echo "     SSO 시작 URL: $SSO_START_URL"
else
    # SSO 미설정 시 IAM Identity Center 인스턴스를 감지해 설정 가이드 출력
    _INSTANCE_JSON=$(aws sso-admin list-instances --region "$AWS_REGION" \
        --query 'Instances[0]' --output json 2>/dev/null || echo "null")
    _IDENTITY_STORE_ID=$(echo "$_INSTANCE_JSON" | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('IdentityStoreId','') if d else '')" 2>/dev/null)

    if [ -n "$_IDENTITY_STORE_ID" ] && [ "$_IDENTITY_STORE_ID" != "None" ]; then
        _AUTO_SSO_URL="https://${_IDENTITY_STORE_ID}.awsapps.com/start"
        _CALLBACK="${JUPYTERHUB_PUBLIC_URL:-https://<NLB-URL>}/hub/oauth_callback"
        echo "  ⚠️  SSO 미설정 — IAM Identity Center 감지됨: ${_AUTO_SSO_URL}"
        echo ""
        echo "  ┌─ AWS SSO 활성화 방법 ──────────────────────────────────────────────┐"
        echo "  │ 1. AWS 콘솔 → IAM Identity Center → Applications                 │"
        echo "  │    → Add application → I have an application → OAuth 2.0         │"
        echo "  │ 2. Application name: JupyterHub                                   │"
        echo "  │    Redirect URI: ${_CALLBACK}"
        echo "  │ 3. 생성 후 [Credentials] 탭 → Client ID / Client Secret 복사      │"
        echo "  │ 4. .env 파일에 추가 후 ./deploy.sh 재실행:                         │"
        echo "  │      SSO_START_URL=${_AUTO_SSO_URL}                │"
        echo "  │      SSO_CLIENT_ID=<복사한 Client ID>                             │"
        echo "  │      SSO_CLIENT_SECRET=<복사한 Client Secret>                     │"
        echo "  └───────────────────────────────────────────────────────────────────┘"
    else
        echo "  ℹ️  SSO 미설정 — NativeAuthenticator 유지"
        echo "     (.env에 SSO_START_URL / SSO_CLIENT_ID / SSO_CLIENT_SECRET 설정 시 SSO 활성화)"
    fi
fi

# ============================================================
# 4.3. Hub RBAC — per-user LiteLLM 키 시크릿 생성 권한
# ============================================================
echo ""
echo "[4.3] Hub RBAC 설정..."
kubectl apply -f k8s/hub-rbac.yaml
echo "  ✅ hub-secret-writer Role/RoleBinding 적용 완료"

# ============================================================
# 4.4. LiteLLM 배포
# ============================================================
echo ""
echo "[4.4] PostgreSQL 배포..."
kubectl apply -f k8s/postgres.yaml
echo "  ⏳ PostgreSQL 준비 대기 중..."
kubectl wait pod -n "$NAMESPACE" -l app=postgres \
    --for=condition=Ready --timeout=120s 2>/dev/null \
    || echo "  ⚠️  PostgreSQL 준비 타임아웃 (계속 진행)"

# LiteLLM schema initialization via prisma db push.
# Must run once before LiteLLM starts (DISABLE_SCHEMA_UPDATE=true skips auto-migration
# to avoid downloading the Prisma migration engine binary on every pod restart).
_DB_URL=$(kubectl get secret postgres-secrets -n "$NAMESPACE" \
    -o jsonpath='{.data.database-url}' 2>/dev/null | base64 -d)
_TABLES=$(kubectl exec -n "$NAMESPACE" postgres-0 -- \
    psql -U litellm -d litellm -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null || echo "0")
if [ "${_TABLES:-0}" -lt 5 ] 2>/dev/null; then
    echo "  📌 LiteLLM DB 스키마 초기화 중 (prisma db push)..."
    kubectl run litellm-db-init --restart=Never \
        --image=ghcr.io/berriai/litellm:main-stable \
        --namespace="$NAMESPACE" \
        --env="DATABASE_URL=${_DB_URL}" \
        --command -- sh -c \
        "/app/.venv/bin/prisma db push --schema /app/schema.prisma --accept-data-loss 2>&1 | tail -3"
    kubectl wait pod/litellm-db-init -n "$NAMESPACE" \
        --for=condition=Ready=false --timeout=120s 2>/dev/null || true
    kubectl logs litellm-db-init -n "$NAMESPACE" 2>/dev/null | tail -5
    kubectl delete pod litellm-db-init -n "$NAMESPACE" --ignore-not-found 2>/dev/null
    echo "  ✅ DB 스키마 초기화 완료"
else
    echo "  ✅ 기존 DB 스키마 재사용 (테이블 ${_TABLES}개)"
fi
echo "  ✅ PostgreSQL 배포 완료"

echo ""
echo "[4.5] LiteLLM 배포..."

sed "s|__LITELLM_ROLE_ARN__|${LITELLM_ROLE_ARN}|g" k8s/litellm.yaml \
    | kubectl apply -f -
kubectl rollout status deployment/litellm -n "$NAMESPACE" --timeout=120s 2>/dev/null \
    || echo "  ⚠️  LiteLLM rollout 대기 타임아웃 (백그라운드에서 계속 진행 중)"
echo "  ✅ LiteLLM 배포 완료"
echo "  📊 LiteLLM Admin UI: http://litellm:4000/ui (클러스터 내부, kubectl port-forward 필요)"

# ============================================================
# 5. Helm 배포
# ============================================================
echo ""
echo "[5/5] Helm 배포..."

PROXY_TOKEN="${CONFIGPROXY_AUTH_TOKEN:-$(openssl rand -hex 32)}"
ADMIN_USER="${JUPYTERHUB_ADMIN:-admin}"
TLS_SECRET="jupyterhub-tls"

# Normalize JUPYTERHUB_PUBLIC_URL to always use https://
if [ -n "${JUPYTERHUB_PUBLIC_URL:-}" ]; then
    _host="${JUPYTERHUB_PUBLIC_URL#https://}"
    _host="${_host#http://}"
    JUPYTERHUB_PUBLIC_URL="https://${_host}"
fi

# Reuse existing NLB hostname from a prior deployment.
if [ -z "${JUPYTERHUB_PUBLIC_URL:-}" ]; then
    EXISTING_HOST=$(kubectl get svc -n "$NAMESPACE" proxy-public \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [ -n "$EXISTING_HOST" ]; then
        JUPYTERHUB_PUBLIC_URL="https://${EXISTING_HOST}"
        echo "  📡 기존 NLB 주소 재사용: ${JUPYTERHUB_PUBLIC_URL}"
    fi
fi

# Create a CA-signed TLS cert and store as a K8s secret.
# A standalone self-signed cert is blocked by browsers for service worker registration;
# a proper CA chain allows users to install jupyterhub-ca.crt once and get full trust.
_ensure_tls_secret() {
    local host="$1"
    if kubectl get secret -n "$NAMESPACE" "$TLS_SECRET" &>/dev/null; then
        echo "  ✅ 기존 TLS 시크릿 재사용 ($TLS_SECRET)"
        return
    fi
    echo "  🔐 CA 인증서 및 서버 인증서 생성 중..."
    # Root CA
    openssl genrsa -out /tmp/jh-ca.key 4096 2>/dev/null
    openssl req -new -x509 -days 3650 \
        -key /tmp/jh-ca.key -out /tmp/jh-ca.crt \
        -subj "/CN=JupyterHub Dev CA/O=Dev" 2>/dev/null
    # Server cert signed by CA (CN max 64 chars; full hostname goes in SAN)
    openssl genrsa -out /tmp/jh-server.key 2048 2>/dev/null
    openssl req -new -key /tmp/jh-server.key -out /tmp/jh-server.csr \
        -subj "/CN=jupyterhub" 2>/dev/null
    echo "subjectAltName=DNS:${host}" > /tmp/jh-ext.cnf
    openssl x509 -req -days 3650 \
        -in /tmp/jh-server.csr \
        -CA /tmp/jh-ca.crt -CAkey /tmp/jh-ca.key -CAcreateserial \
        -extfile /tmp/jh-ext.cnf \
        -out /tmp/jh-server.crt 2>/dev/null
    # Full chain in the secret
    cat /tmp/jh-server.crt /tmp/jh-ca.crt > /tmp/jh-chain.crt
    kubectl create secret tls "$TLS_SECRET" \
        -n "$NAMESPACE" \
        --cert=/tmp/jh-chain.crt \
        --key=/tmp/jh-server.key
    # Save CA cert locally for distribution to users
    cp /tmp/jh-ca.crt "${SCRIPT_DIR}/jupyterhub-ca.crt"
    rm -f /tmp/jh-ca.{key,crt,srl} /tmp/jh-server.{key,csr,crt} /tmp/jh-chain.crt /tmp/jh-ext.cnf
    echo "  ✅ TLS 시크릿 생성 완료 ($TLS_SECRET)"
    echo "  📄 CA 인증서 저장됨: jupyterhub-ca.crt"
    echo "     브라우저에 설치하는 방법:"
    echo "     macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain jupyterhub-ca.crt"
    echo "     Windows: certlm.msc → 신뢰할 수 있는 루트 인증 기관 → 인증서 → 모든 작업 → 가져오기"
}

# Helper: run helm upgrade with HTTPS and JUPYTERHUB_PUBLIC_URL set.
_helm_upgrade_https() {
    local install_flag="${1:---reuse-values}"
    local extra_args=()
    if [ "$install_flag" = "--install" ]; then
        extra_args=(
            --values helm/values.yaml
            --set hub.image.name="${ECR_REGISTRY}/jupyterhub-hub"
            --set hub.image.tag=latest
            --set singleuser.image.name="${ECR_REGISTRY}/codeserver-kbdev"
            --set singleuser.image.tag=latest
            --set proxy.secretToken="${PROXY_TOKEN}"
            --set "hub.config.Authenticator.admin_users[0]=${ADMIN_USER}"
        )
    fi
    helm upgrade --install "$HELM_RELEASE" jupyterhub/jupyterhub \
        --namespace "$NAMESPACE" \
        "${extra_args[@]}" \
        --set "singleuser.extraEnv.JUPYTERHUB_PUBLIC_URL=${JUPYTERHUB_PUBLIC_URL}" \
        --set "hub.extraEnv.JUPYTERHUB_PUBLIC_URL=${JUPYTERHUB_PUBLIC_URL}" \
        --set "proxy.https.enabled=true" \
        --set "proxy.https.type=secret" \
        --set "proxy.https.secret.name=${TLS_SECRET}" \
        --timeout 10m \
        --wait
}

if [ -n "${JUPYTERHUB_PUBLIC_URL:-}" ]; then
    # NLB hostname known — create cert and deploy with HTTPS in one shot.
    _host="${JUPYTERHUB_PUBLIC_URL#https://}"
    _ensure_tls_secret "$_host"
    _helm_upgrade_https --install
else
    # First-ever deploy: bring up without HTTPS to obtain the NLB hostname,
    # then re-deploy with HTTPS once the hostname is known.
    helm upgrade --install "$HELM_RELEASE" jupyterhub/jupyterhub \
        --namespace "$NAMESPACE" \
        --values helm/values.yaml \
        --set hub.image.name="${ECR_REGISTRY}/jupyterhub-hub" \
        --set hub.image.tag=latest \
        --set singleuser.image.name="${ECR_REGISTRY}/codeserver-kbdev" \
        --set singleuser.image.tag=latest \
        --set proxy.secretToken="${PROXY_TOKEN}" \
        --set "hub.config.Authenticator.admin_users[0]=${ADMIN_USER}" \
        --timeout 10m \
        --wait

    echo "  ⏳ NLB 주소 대기 중 (최대 3분)..."
    for i in $(seq 1 18); do
        NEW_HOST=$(kubectl get svc -n "$NAMESPACE" proxy-public \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
        if [ -n "$NEW_HOST" ]; then
            JUPYTERHUB_PUBLIC_URL="https://${NEW_HOST}"
            echo "  📡 NLB 주소 확보: ${JUPYTERHUB_PUBLIC_URL}"
            _ensure_tls_secret "$NEW_HOST"
            _helm_upgrade_https --reuse-values
            break
        fi
        sleep 10
    done
fi

echo ""
echo "============================================================"
echo " ✅ 배포 완료!"
echo ""
echo " 접속 URL: ${JUPYTERHUB_PUBLIC_URL:-https://$(kubectl get svc -n ${NAMESPACE} proxy-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)}"
echo " ⚠️  최초 접속 시 브라우저에서 자체서명 인증서 경고가 표시됩니다."
echo "    '고급' → '안전하지 않음으로 이동' 클릭 후 정상 사용 가능합니다."
echo ""
echo " 로그 확인:   kubectl logs -n ${NAMESPACE} -l component=hub -f"
echo " 파드 확인:   kubectl get pods -n ${NAMESPACE}"
echo " 삭제:        helm uninstall ${HELM_RELEASE} -n ${NAMESPACE}"
echo "============================================================"
