#!/bin/bash
# DinD Entrypoint: Docker daemon을 백그라운드로 시작한 후 원래 명령 실행
# 이 스크립트는 start-notebook.d/ 훅으로 source 됩니다.
# 주의: Jupyter 서버 시작을 블로킹하지 않도록 대기 로직을 백그라운드에서 실행해야 합니다.

# root 권한이 있을 때만 dockerd 시작
if [ "$(id -u)" = "0" ] || sudo -n true 2>/dev/null; then
    # Docker daemon이 이미 실행 중이 아닌 경우에만 시작
    if ! pgrep -x dockerd > /dev/null 2>&1; then
        echo "Starting Docker daemon (DinD) in background..."
        sudo supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || \
        sudo nohup dockerd --host=unix:///var/run/docker.sock --storage-driver=overlay2 \
            > /var/log/dockerd.out.log 2> /var/log/dockerd.err.log &

        # 백그라운드에서 dockerd 준비 대기 (Jupyter 서버 시작을 블로킹하지 않음)
        (
            for i in $(seq 1 30); do
                if sudo docker info > /dev/null 2>&1; then
                    echo "Docker daemon is ready."
                    # jovyan 사용자가 docker.sock에 접근 가능하도록 권한 설정
                    if [ -S /var/run/docker.sock ]; then
                        sudo chmod 666 /var/run/docker.sock
                    fi
                    exit 0
                fi
                sleep 1
            done
            echo "Warning: Docker daemon failed to start within 30 seconds. DinD may not be available."
        ) &
    fi
fi
