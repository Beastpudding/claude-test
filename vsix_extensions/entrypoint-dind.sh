#!/bin/bash
# Docker-in-Docker startup hook (start-notebook.d)

if [ "$(id -u)" = "0" ] || sudo -n true 2>/dev/null; then
    if ! pgrep -x dockerd > /dev/null 2>&1; then
        echo "[DinD] Starting Docker daemon..."

        if [ -f /etc/supervisor/conf.d/dockerd.conf ]; then
            sudo supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null &
        else
            sudo dockerd --host=unix:///var/run/docker.sock --storage-driver=overlay2 \
                > /var/log/dockerd.out.log 2> /var/log/dockerd.err.log &
        fi

        (
            MAX_WAIT=60
            for i in $(seq 1 $MAX_WAIT); do
                if sudo docker info > /dev/null 2>&1; then
                    echo "[DinD] Docker daemon ready (waited ${i}s)"
                    [ -S /var/run/docker.sock ] && sudo chmod 666 /var/run/docker.sock
                    exit 0
                fi
                sleep 1
            done
            echo "[DinD] WARNING: Docker daemon failed to start within ${MAX_WAIT}s"
        ) &
    else
        echo "[DinD] Docker daemon already running"
        [ -S /var/run/docker.sock ] && sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
    fi
fi
