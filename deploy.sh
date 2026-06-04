#!/bin/bash
set -euo pipefail

# ============================================================
# JupyterHub EKS 배포 스크립트 (Cognito + LiteLLM + Bedrock)
# 사용법: ./deploy.sh
#
# 사전 조건:
#   - aws CLI, docker, helm, kubectl 설치
#   - aws configure (또는 EC2 IAM 역할) 설정
#   - EKS 클러스터 생성 완료
#   - Cognito User Pool + App Client 생성 완료
#   - .env 파일에 변수 설정 (.env.example 참고)
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
COGNITO_DOMAIN="${COGNITO_DOMAIN:-}"
COGNITO_CLIENT_ID="${COGNITO_CLIENT_ID:-}"
COGNITO_CLIENT_SECRET="${COGNITO_CLIENT_SECRET:-}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-}"

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# EKS 노드 아키텍처. t3/t3a/m5 등 일반 EKS 노드는 amd64.
TARGET_ARCH="${TARGET_ARCH:-amd64}"
ARCH="$TARGET_ARCH"

echo "============================================================"
echo " JupyterHub EKS 배포"
echo " Region:  $AWS_REGION"
echo " Account: $AWS_ACCOUNT_ID"
echo " Cluster: $EKS_CLUSTER_NAME"
echo " Arch:    $ARCH"
echo " Cognito: ${COGNITO_DOMAIN:-비활성 (NativeAuthenticator 폴백)}"
echo "============================================================"

# ============================================================
# 1. 사전 준비 확인
# ============================================================
echo ""
echo "[1] 사전 준비 확인..."

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
echo "[2] ECR 준비..."

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
echo "[3] Docker 이미지 빌드 및 푸시..."

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
echo "[4] Kubernetes 설정..."

aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

helm repo add jupyterhub https://hub.jupyter.org/helm-chart/ 2>/dev/null || true
helm repo update
echo "  ✅ kubeconfig 및 Helm repo 업데이트 완료"

# ============================================================
# 4.0. Karpenter — singleuser 자동 스케일링
# ============================================================
# Karpenter가 클러스터에 이미 설치돼있어야 NodePool 적용 가능.
# 부트스트랩(IAM 역할/SQS/CFN)은 CLAUDE.md "Karpenter bootstrap" 섹션 참고.
echo ""
echo "[4.0] Karpenter NodePool 동기화..."
if kubectl get crd nodepools.karpenter.sh &>/dev/null; then
    sed "s|__CLUSTER_NAME__|${EKS_CLUSTER_NAME}|g" k8s/karpenter-nodepool.yaml \
        | kubectl apply -f - >/dev/null
    echo "  ✅ NodePool/EC2NodeClass 적용 완료 (cluster: ${EKS_CLUSTER_NAME})"
    echo "     spawn 폭주 시 m5/m6i large~2xlarge 자동 provision, idle 시 자동 종료"
else
    echo "  ⚠️  Karpenter CRD 미설치 — NodePool 스킵"
    echo "     설치 방법: CLAUDE.md → 'Karpenter bootstrap' 섹션 참고"
fi

# ============================================================
# 4.1. IRSA — LiteLLM Bedrock 접근 권한
# ============================================================
echo ""
echo "[4.1] LiteLLM IRSA 설정..."

LITELLM_SA="litellm"
LITELLM_ROLE="JupyterHubLiteLLM-${EKS_CLUSTER_NAME}"

# Get OIDC provider for the cluster
OIDC_URL=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" \
    --query "cluster.identity.oidc.issuer" --output text)
OIDC_PROVIDER="${OIDC_URL#https://}"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"

# Register OIDC provider in IAM if not already done
if ! aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn, '${OIDC_PROVIDER}')]" --output text | grep -q "${OIDC_PROVIDER}"; then
    echo "  📌 OIDC provider IAM 등록 중..."
    THUMBPRINT=$(echo | openssl s_client -servername oidc.eks.${AWS_REGION}.amazonaws.com \
        -showcerts -connect oidc.eks.${AWS_REGION}.amazonaws.com:443 2>/dev/null | \
        openssl x509 -fingerprint -noout -sha1 | sed 's/SHA1 Fingerprint=//; s/://g' | tr 'A-F' 'a-f')
    aws iam create-open-id-connect-provider \
        --url "$OIDC_URL" \
        --client-id-list sts.amazonaws.com \
        --thumbprint-list "$THUMBPRINT" > /dev/null
    echo "  ✅ OIDC provider 등록 완료"
else
    echo "  ✅ OIDC provider 이미 등록됨"
fi

# Create Bedrock IAM policy (idempotent)
POLICY_NAME="JupyterHubBedrockInvoke"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
if ! aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
    echo "  📌 Bedrock IAM 정책 생성 중..."
    POLICY_ARN=$(aws iam create-policy \
        --policy-name "$POLICY_NAME" \
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
# 4.2. K8s 시크릿 — LiteLLM 마스터 키 / PostgreSQL / Cognito 자격증명
# ============================================================
echo ""
echo "[4.2] K8s 시크릿 설정..."

# LiteLLM master key (재배포에도 같은 키 유지하도록 .env에 저장)
if [ -z "$LITELLM_MASTER_KEY" ]; then
    LITELLM_MASTER_KEY="sk-$(openssl rand -hex 24)"
    echo "  🔑 LiteLLM master key 새로 생성 (.env에 저장)"
    if grep -q "^LITELLM_MASTER_KEY=" .env 2>/dev/null; then
        sed -i.bak "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}|" .env && rm -f .env.bak
    else
        echo "LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}" >> .env
    fi
fi
kubectl create secret generic litellm-secrets -n "$NAMESPACE" \
    --from-literal=master-key="$LITELLM_MASTER_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

# Postgres password — random one-time, regenerate-safe via Secret diff
if ! kubectl get secret postgres-secrets -n "$NAMESPACE" &>/dev/null; then
    PG_PASS=$(openssl rand -hex 16)
    kubectl create secret generic postgres-secrets -n "$NAMESPACE" \
        --from-literal=password="$PG_PASS" \
        --from-literal=database-url="postgresql://litellm:${PG_PASS}@postgres:5432/litellm"
    echo "  ✅ postgres-secrets 생성"
else
    echo "  ✅ 기존 postgres-secrets 재사용"
fi

# Cognito OIDC secret
if [ -n "$COGNITO_DOMAIN" ] && [ -n "$COGNITO_CLIENT_ID" ] && [ -n "$COGNITO_CLIENT_SECRET" ]; then
    kubectl delete secret jupyterhub-cognito -n "$NAMESPACE" 2>/dev/null || true
    kubectl create secret generic jupyterhub-cognito \
        -n "$NAMESPACE" \
        --from-literal=domain="$COGNITO_DOMAIN" \
        --from-literal=client-id="$COGNITO_CLIENT_ID" \
        --from-literal=client-secret="$COGNITO_CLIENT_SECRET"
    echo "  ✅ jupyterhub-cognito 시크릿 생성 완료"
    echo "     Cognito 도메인: $COGNITO_DOMAIN"
    # Migration: remove legacy jupyterhub-sso secret if present
    kubectl delete secret jupyterhub-sso -n "$NAMESPACE" --ignore-not-found 2>/dev/null
else
    echo "  ℹ️  Cognito 미설정 — NativeAuthenticator 폴백 사용"
    echo "     (.env에 COGNITO_DOMAIN / COGNITO_CLIENT_ID / COGNITO_CLIENT_SECRET 설정 시 OIDC 활성화)"
fi

# ============================================================
# 4.2.0b. Cognito Pre Sign-up Lambda 동기화
# ============================================================
# k8s/lambdas/pre_signup.py를 jupyterhub-pre-signup Lambda에 업로드.
# Lambda 자체와 Cognito 트리거 등록은 콘솔에서 1회 수행한 상태를 전제.
# (도메인 화이트리스트 등 정책 변경 시 .py만 수정 → ./deploy.sh로 자동 반영)
if [ -f k8s/lambdas/pre_signup.py ] && \
   aws lambda get-function --function-name jupyterhub-pre-signup \
       --region "$AWS_REGION" &>/dev/null; then
    echo ""
    echo "[4.2.0b] Pre Sign-up Lambda 동기화..."
    _LAMBDA_ZIP=$(mktemp -d)/pre_signup.zip
    (cd k8s/lambdas && zip -q "$_LAMBDA_ZIP" pre_signup.py)
    aws lambda update-function-code \
        --function-name jupyterhub-pre-signup \
        --zip-file "fileb://$_LAMBDA_ZIP" \
        --region "$AWS_REGION" \
        --query "LastModified" --output text > /dev/null
    rm -rf "$(dirname "$_LAMBDA_ZIP")"
    echo "  ✅ jupyterhub-pre-signup 코드 업데이트 완료"
fi

# ============================================================
# 4.2.0. JupyterHub 커스텀 템플릿 (page/spawn/login.html) — ConfigMap
# ============================================================
# k8s/templates/*.html → hub-templates ConfigMap → hub 파드의
# /etc/jupyterhub/custom-templates 에 마운트. c.JupyterHub.template_paths가
# 이 경로를 가리키므로 z2jh 기본 템플릿 대신 우리 한글 브랜딩 버전이 렌더링됨.
if [ -d k8s/templates ] && compgen -G "k8s/templates/*.html" >/dev/null; then
    kubectl create configmap hub-templates -n "$NAMESPACE" \
        $(for f in k8s/templates/*.html; do echo "--from-file=$(basename "$f")=$f"; done) \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "  ✅ hub-templates ConfigMap 동기화 완료 ($(ls k8s/templates/*.html | wc -l | tr -d ' ')개 템플릿)"
fi

# ============================================================
# 4.3. Hub RBAC — per-user LiteLLM 키 시크릿 생성 권한
# ============================================================
echo ""
echo "[4.3] Hub RBAC 설정..."
kubectl apply -f k8s/hub-rbac.yaml
echo "  ✅ hub-secret-writer Role/RoleBinding 적용 완료"

# ============================================================
# 4.4. PostgreSQL 배포 (LiteLLM 백엔드)
# ============================================================
echo ""
echo "[4.4] PostgreSQL 배포..."
kubectl apply -f k8s/postgres.yaml
kubectl rollout status -n "$NAMESPACE" statefulset/postgres --timeout=180s
echo "  ✅ Postgres Ready"

# ============================================================
# 4.5. LiteLLM 배포 (Bedrock 프록시)
# ============================================================
echo ""
echo "[4.5] LiteLLM 배포..."
sed "s|__LITELLM_ROLE_ARN__|${LITELLM_ROLE_ARN}|g" k8s/litellm.yaml \
    | kubectl apply -f -
kubectl rollout status -n "$NAMESPACE" deployment/litellm --timeout=240s
echo "  ✅ LiteLLM Ready"

# ============================================================
# 5. Helm 배포
# ============================================================
echo ""
echo "[5] Helm 배포..."

PROXY_TOKEN="${CONFIGPROXY_AUTH_TOKEN:-$(openssl rand -hex 32)}"
ADMIN_USER="${JUPYTERHUB_ADMIN:-admin}"

# TLS termination is handled by CloudFront in front of the NLB (publicly-trusted
# Amazon cert on `*.cloudfront.net`). The chp proxy itself serves plain HTTP;
# CloudFront → NLB :80 → proxy. JUPYTERHUB_PUBLIC_URL must be the CloudFront URL.
# Without JUPYTERHUB_PUBLIC_URL set, the first deploy can't generate correct
# Cognito callback URLs — set it in .env to your CloudFront distribution domain.

# Normalize JUPYTERHUB_PUBLIC_URL
if [ -n "${JUPYTERHUB_PUBLIC_URL:-}" ]; then
    _host="${JUPYTERHUB_PUBLIC_URL#https://}"
    _host="${_host#http://}"
    JUPYTERHUB_PUBLIC_URL="https://${_host}"
fi

helm upgrade --install "$HELM_RELEASE" jupyterhub/jupyterhub \
    --namespace "$NAMESPACE" \
    --values helm/values.yaml \
    --set hub.image.name="${ECR_REGISTRY}/jupyterhub-hub" \
    --set hub.image.tag=latest \
    --set singleuser.image.name="${ECR_REGISTRY}/codeserver-kbdev" \
    --set singleuser.image.tag=latest \
    --set proxy.secretToken="${PROXY_TOKEN}" \
    --set "hub.config.Authenticator.admin_users[0]=${ADMIN_USER}" \
    --set "singleuser.extraEnv.JUPYTERHUB_PUBLIC_URL=${JUPYTERHUB_PUBLIC_URL}" \
    --set "hub.extraEnv.JUPYTERHUB_PUBLIC_URL=${JUPYTERHUB_PUBLIC_URL}" \
    --set "proxy.https.enabled=false" \
    --timeout 10m \
    --wait

if [ -z "${JUPYTERHUB_PUBLIC_URL:-}" ]; then
    echo ""
    echo "  ⚠️  JUPYTERHUB_PUBLIC_URL이 설정되지 않았습니다."
fi

echo ""
echo "============================================================"
echo " ✅ 배포 완료"
echo "============================================================"
echo " 접속 URL: ${JUPYTERHUB_PUBLIC_URL}"
echo "============================================================"
