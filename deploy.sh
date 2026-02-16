#!/bin/bash
set -euo pipefail

# ============================================================
# JupyterHub + Code-Server 배포 스크립트
# 사용법: ./deploy.sh [--airgap]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

AIRGAP=false
if [[ "${1:-}" == "--airgap" ]]; then
    AIRGAP=true
fi

echo "============================================================"
echo " JupyterHub + Code-Server 배포"
echo " 폐쇄망 모드: $AIRGAP"
echo "============================================================"

# ============================================================
# 1. 사전 준비 확인
# ============================================================
echo ""
echo "[1/5] 사전 준비 확인..."

# Docker 확인
if ! command -v docker &> /dev/null; then
    echo "❌ Docker가 설치되어 있지 않습니다."
    exit 1
fi
echo "  ✅ Docker: $(docker --version)"

# Docker Compose 확인
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo "❌ Docker Compose가 설치되어 있지 않습니다."
    exit 1
fi
echo "  ✅ Docker Compose: $($COMPOSE_CMD version 2>/dev/null || echo 'available')"

# .env 파일 확인
if [ ! -f ".env" ]; then
    echo "  ⚠️  .env 파일이 없습니다. .env.example에서 복사합니다..."
    cp .env.example .env
    echo "  ✅ .env 파일 생성 완료"
fi

# ============================================================
# 2. code-server 디렉토리 및 .deb 파일 확인
# ============================================================
echo ""
echo "[2/5] 필수 파일 확인..."

# code-server 설정 디렉토리
if [ ! -d "./code-server" ]; then
    echo "  ⚠️  code-server/ 디렉토리가 없습니다. 기본 디렉토리를 생성합니다..."
    mkdir -p ./code-server
    echo "  ✅ code-server/ 디렉토리 생성 완료"
fi

# code-server .deb 파일 확인
CODE_VERSION="${CODE_VERSION:-4.95.3}"

# 시스템 아키텍처 자동 감지
if [ -z "${TARGETARCH:-}" ]; then
    MACHINE_ARCH="$(uname -m)"
    case "$MACHINE_ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            echo "❌ 지원하지 않는 아키텍처: $MACHINE_ARCH"
            exit 1
            ;;
    esac
else
    ARCH="$TARGETARCH"
fi
echo "  시스템 아키텍처: $ARCH"

DEB_FILE="code-server_${CODE_VERSION}_${ARCH}.deb"

if [ ! -f "$DEB_FILE" ]; then
    if [ "$AIRGAP" = true ]; then
        echo "❌ 폐쇄망 모드: $DEB_FILE 파일이 필요합니다."
        echo "   인터넷이 가능한 환경에서 아래 명령으로 미리 다운로드하세요:"
        echo "   curl -fOL https://github.com/coder/code-server/releases/download/v${CODE_VERSION}/code-server_${CODE_VERSION}_${ARCH}.deb"
        exit 1
    else
        echo "  ⬇️  code-server .deb 다운로드 중..."
        curl -fOL "https://github.com/coder/code-server/releases/download/v${CODE_VERSION}/${DEB_FILE}"
        echo "  ✅ $DEB_FILE 다운로드 완료"
    fi
fi
echo "  ✅ $DEB_FILE 확인 완료"

# ============================================================
# 3. 기존 컨테이너 정리
# ============================================================
echo ""
echo "[3/5] 기존 컨테이너 정리..."

$COMPOSE_CMD down --remove-orphans 2>/dev/null || true
echo "  ✅ 정리 완료"

# ============================================================
# 4. Docker 이미지 빌드
# ============================================================
echo ""
echo "[4/5] Docker 이미지 빌드..."

# 노트북 이미지 빌드
echo "  🔨 code-server 노트북 이미지 빌드 중..."
docker build \
    -f Dockerfile.codeserver \
    -t codeserver-kbdev:local \
    --build-arg CODE_VERSION="${CODE_VERSION}" \
    --build-arg TARGETARCH="${ARCH}" \
    ${PIP_INDEX_URL:+--build-arg PIP_INDEX_URL="$PIP_INDEX_URL"} \
    ${PIP_TRUSTED_HOST:+--build-arg PIP_TRUSTED_HOST="$PIP_TRUSTED_HOST"} \
    .
echo "  ✅ codeserver-kbdev:local 빌드 완료"

# JupyterHub 이미지 빌드
echo "  🔨 JupyterHub 이미지 빌드 중..."
$COMPOSE_CMD build hub
echo "  ✅ jupyterhub:local 빌드 완료"

# ============================================================
# 5. 서비스 시작
# ============================================================
echo ""
echo "[5/5] 서비스 시작..."

$COMPOSE_CMD up -d

echo ""
echo "============================================================"
echo " ✅ 배포 완료!"
echo ""
echo " JupyterHub 접속: http://localhost:${JUPYTERHUB_PORT:-8000}"
echo " 관리자 계정: ${JUPYTERHUB_ADMIN:-admin}"
echo ""
echo " 로그 확인: $COMPOSE_CMD logs -f hub"
echo " 중지:     $COMPOSE_CMD down"
echo "============================================================"
