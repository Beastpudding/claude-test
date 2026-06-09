#!/bin/bash
# EC2 cloud-init: Docker + EBS 마운트 + Nexus 단일 컨테이너 기동 (compose 없이).
set -euxo pipefail

EBS_DEVICE="__EBS_DEVICE__"

# ── EBS 마운트 (/nexus-data) ────────────────────────────────────
mkdir -p /nexus-data
if ! blkid "${EBS_DEVICE}" >/dev/null 2>&1; then
    mkfs -t ext4 "${EBS_DEVICE}"
fi
if ! grep -q "${EBS_DEVICE}" /etc/fstab; then
    echo "${EBS_DEVICE}  /nexus-data  ext4  defaults,nofail  0  2" >> /etc/fstab
fi
mountpoint -q /nexus-data || mount /nexus-data
chown -R 200:200 /nexus-data        # sonatype/nexus3 UID 200

# ── Docker ──────────────────────────────────────────────────────
dnf install -y --allowerasing curl wget jq tar
dnf install -y docker
systemctl enable --now docker

# ── systemd unit: 단일 docker run으로 nexus 기동 ────────────────
cat > /etc/systemd/system/nexus.service <<'SVC_EOF'
[Unit]
Description=Nexus OSS 3
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=600
ExecStartPre=-/usr/bin/docker rm -f nexus
# systemd ExecStart는 \\ 이스케이프 지원 안 함. 환경변수 값은 따옴표로 감싸야 한 인자로 전달됨.
ExecStart=/usr/bin/docker run --rm --name nexus \
    -p 80:8081 \
    -v /nexus-data:/nexus-data \
    -e "INSTALL4J_ADD_VM_PARAMS=-Xms2g -Xmx3g -XX:MaxDirectMemorySize=2g -Djava.util.prefs.userRoot=/nexus-data/javaprefs" \
    sonatype/nexus3:3.70.1
ExecStop=/usr/bin/docker stop nexus

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable --now nexus.service

echo "Nexus 컨테이너 기동 시작. 첫 부팅 5~7분 소요."
