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

echo "============================================================"
echo " JupyterHub EKS 배포"
echo " Region:  $AWS_REGION"
echo " Account: $AWS_ACCOUNT_ID"
echo " Cluster: $EKS_CLUSTER_NAME"
echo " Arch:    $ARCH"
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

helm repo add jupyterhub https://hub.jupyter.org/helm-chart/ 2>/dev/null || true
helm repo update
echo "  ✅ kubeconfig 및 Helm repo 업데이트 완료"

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
