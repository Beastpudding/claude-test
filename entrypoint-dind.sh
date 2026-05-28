#!/bin/bash
# Docker-in-Docker startup hook (jupyter's start.sh sources this as jovyan).
#
# Strategy: launch dockerd fully detached via `setsid` + `nohup` + stdio
# redirection. Without full detachment the daemon dies when start.sh later
# `exec`s jupyter-singleuser (tini -g propagates signals to the process group).
#
# Idempotent: re-running just fixes socket perms.

if pgrep -x dockerd >/dev/null 2>&1; then
    [ -S /var/run/docker.sock ] && sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
    return 0 2>/dev/null || exit 0
fi

echo "[DinD] Starting dockerd..."
sudo -b setsid bash -c '
    nohup /usr/bin/dockerd \
        --host=unix:///var/run/docker.sock \
        --storage-driver=vfs \
        --feature containerd-snapshotter=false \
        >/var/log/dockerd.log 2>&1 </dev/null
' >/dev/null 2>&1
# NOTE on flags (nested DinD on EKS):
# --storage-driver=vfs            EKS nodes already use overlayfs; nested overlay2
#                                 fails to mount. vfs is slow but always works.
# --feature containerd-snapshotter=false
#                                 Docker 29+ defaults to containerd's snapshotter
#                                 for runtime, which also tries overlay and fails
#                                 even with vfs as graphdriver. Forcing the
#                                 classic dockerd graphdriver path keeps it on vfs.

# Wait for socket so jovyan can run `docker ...` (no sudo needed) immediately.
for i in $(seq 1 60); do
    if [ -S /var/run/docker.sock ]; then
        sudo chmod 666 /var/run/docker.sock 2>/dev/null
        echo "[DinD] dockerd ready in ${i}s"
        return 0 2>/dev/null || exit 0
    fi
    sleep 1
done
echo "[DinD] WARNING: dockerd socket not ready within 60s. Check /var/log/dockerd.log"
return 0 2>/dev/null || exit 0
