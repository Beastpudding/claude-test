#!/bin/bash
# ============================================================
# DinD + pip 설정 Entrypoint
# start-notebook.d/ 훅으로 컨테이너 시작 시 자동 실행
# ============================================================

# ----------------------------------------------------------
# 1) pip.conf 동적 생성 (폐쇄망 내부 PyPI 미러)
#    환경변수 PIP_INDEX_URL / PIP_TRUSTED_HOST 가 있으면
#    글로벌 pip.conf 및 각 conda 환경별 pip.conf를 생성
# ----------------------------------------------------------
if [ -n "${PIP_INDEX_URL:-}" ]; then
    echo "[pip] Configuring internal PyPI mirror: ${PIP_INDEX_URL}"

    TRUSTED="${PIP_TRUSTED_HOST:-}"

    # 글로벌 pip.conf (/etc/pip/pip.conf) — 모든 사용자·모든 Python에 적용
    sudo mkdir -p /etc/pip
    {
        echo "[global]"
        echo "index-url = ${PIP_INDEX_URL}"
        [ -n "$TRUSTED" ] && echo "trusted-host = ${TRUSTED}"
    } | sudo tee /etc/pip/pip.conf > /dev/null

    # 각 conda 환경 (py37, py38, py39) 별 pip.conf 도 설정
    for ENV_NAME in py37 py38 py39; do
        ENV_BIN="/opt/conda/envs/${ENV_NAME}/bin/pip"
        if [ -x "$ENV_BIN" ]; then
            $ENV_BIN config set global.index-url "${PIP_INDEX_URL}" 2>/dev/null || true
            [ -n "$TRUSTED" ] && $ENV_BIN config set global.trusted-host "${TRUSTED}" 2>/dev/null || true
        fi
    done

    # base conda 환경도 설정
    if [ -x /opt/conda/bin/pip ]; then
        /opt/conda/bin/pip config set global.index-url "${PIP_INDEX_URL}" 2>/dev/null || true
        [ -n "$TRUSTED" ] && /opt/conda/bin/pip config set global.trusted-host "${TRUSTED}" 2>/dev/null || true
    fi

    echo "[pip] pip.conf configured for all Python environments."
else
    echo "[pip] PIP_INDEX_URL not set — using default PyPI."
fi

# ----------------------------------------------------------
# 2) Docker-in-Docker (dockerd) 백그라운드 시작
#    Jupyter 서버 시작을 블로킹하지 않도록 대기 로직은 서브셸에서 실행
# ----------------------------------------------------------
if [ "$(id -u)" = "0" ] || sudo -n true 2>/dev/null; then
    if ! pgrep -x dockerd > /dev/null 2>&1; then
        echo "[DinD] Starting Docker daemon in background..."

        if [ -f /etc/supervisor/conf.d/dockerd.conf ]; then
            sudo supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null &
        else
            sudo dockerd --host=unix:///var/run/docker.sock --storage-driver=overlay2 \
                > /var/log/dockerd.out.log 2> /var/log/dockerd.err.log &
        fi

        # 백그라운드에서 dockerd 준비 대기 (Jupyter 서버 시작을 블로킹하지 않음)
        (
            MAX_WAIT=60
            for i in $(seq 1 $MAX_WAIT); do
                if sudo docker info > /dev/null 2>&1; then
                    echo "[DinD] Docker daemon is ready. (waited ${i}s)"
                    if [ -S /var/run/docker.sock ]; then
                        sudo chmod 666 /var/run/docker.sock
                    fi
                    exit 0
                fi
                sleep 1
            done
            echo "[DinD] WARNING: Docker daemon failed to start within ${MAX_WAIT} seconds."
        ) &
    else
        echo "[DinD] Docker daemon is already running."
        if [ -S /var/run/docker.sock ]; then
            sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
        fi
    fi
fi
