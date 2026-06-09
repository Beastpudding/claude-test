#!/bin/bash
# EC2 cloud-init: Harbor offline installer 설치 + EBS 마운트.
# install.sh가 __PLACEHOLDER__ 치환 후 base64로 SSM send-command 전달.
set -euxo pipefail

EBS_DEVICE="__EBS_DEVICE__"           # ex) /dev/nvme1n1
HARBOR_VERSION="__HARBOR_VERSION__"   # ex) v2.10.0

# ── EBS 마운트 (/data) ──────────────────────────────────────────
mkdir -p /data
if ! blkid "${EBS_DEVICE}" >/dev/null 2>&1; then
    mkfs -t ext4 "${EBS_DEVICE}"
fi
if ! grep -q "${EBS_DEVICE}" /etc/fstab; then
    echo "${EBS_DEVICE}  /data  ext4  defaults,nofail  0  2" >> /etc/fstab
fi
mountpoint -q /data || mount /data

# ── Docker + docker-compose (Harbor가 docker-compose stack) ─────
dnf install -y --allowerasing curl wget jq tar
# Amazon Linux 2023: docker는 dnf로 설치, docker-compose는 plugin로 별도
dnf install -y docker
systemctl enable --now docker

# docker compose v2 plugin (Harbor installer가 호환)
DOCKER_CONFIG="${DOCKER_CONFIG:-/usr/local/lib/docker}"
mkdir -p $DOCKER_CONFIG/cli-plugins
curl -fSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
    -o $DOCKER_CONFIG/cli-plugins/docker-compose
chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose

# ── Harbor offline installer 다운로드 ───────────────────────────
mkdir -p /opt/harbor && cd /opt/harbor
INSTALLER="harbor-offline-installer-${HARBOR_VERSION}.tgz"
if [ ! -f "$INSTALLER" ]; then
    curl -fSL -o "$INSTALLER" \
        "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/${INSTALLER}"
fi
tar -xzf "$INSTALLER" --strip-components=1

# ── harbor.yml 생성: 공식 템플릿 사용 + 우리 값으로 덮어쓰기 ────
# 직접 작성하면 Harbor 버전마다 필수 필드 누락으로 깨짐.
# 공식 harbor.yml.tmpl을 base로 두고 hostname/password/data_volume만 교체.
cp /opt/harbor/harbor.yml.tmpl /opt/harbor/harbor.yml

# hostname
sed -i "s|^hostname:.*|hostname: __HARBOR_HOSTNAME_VAR__|" /opt/harbor/harbor.yml

# external_url 추가 (CloudFront HTTPS 종단)
if grep -q "^external_url:" /opt/harbor/harbor.yml; then
    sed -i "s|^external_url:.*|external_url: https://__HARBOR_HOSTNAME_VAR__|" /opt/harbor/harbor.yml
else
    sed -i "/^hostname:/a external_url: https://__HARBOR_HOSTNAME_VAR__" /opt/harbor/harbor.yml
fi

# HTTPS 블록 비활성 (CloudFront에서 처리) — https: 시작 라인 + 그 아래 indent 다 주석
python3 - <<'PYEOF'
with open('/opt/harbor/harbor.yml') as f:
    lines = f.read().splitlines()
out = []
in_https = False
for ln in lines:
    if ln.startswith('https:'):
        in_https = True
        out.append('# ' + ln); continue
    if in_https:
        if ln.startswith('  ') or ln.strip() == '':
            out.append('# ' + ln); continue
        else:
            in_https = False
    out.append(ln)
with open('/opt/harbor/harbor.yml','w') as f:
    f.write(chr(10).join(out) + chr(10))
PYEOF

# admin / db password
sed -i "s|^harbor_admin_password:.*|harbor_admin_password: __HARBOR_ADMIN_PASSWORD_VAR__|" /opt/harbor/harbor.yml
sed -i "s|^\(  password:\).*|\1 __HARBOR_DB_PASSWORD_VAR__|" /opt/harbor/harbor.yml   # database.password (첫 'password:')

# data_volume
sed -i "s|^data_volume:.*|data_volume: /data|" /opt/harbor/harbor.yml

# trivy 비활성 (이미 기본값으로 빠져있을 수도 있지만 명시)
# Harbor 2.10 공식 템플릿은 trivy 블록 포함 — install.sh에 --with-trivy 안 주면 자동 skip.

# ── 설치 실행 (Trivy 비활성) ─────────────────────────────────────
cd /opt/harbor
./install.sh

# ── 부팅 시 자동 시작 (docker-compose stack persist) ────────────
cat > /etc/systemd/system/harbor.service <<'SVC_EOF'
[Unit]
Description=Harbor container registry
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/harbor
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable harbor

# Harbor 자체 install.sh가 컨테이너 띄워둔 상태 — systemd는 다음 부팅부터 관리
echo "Harbor install 완료. http://localhost/ 응답 확인:"
sleep 10
curl -sI -o /dev/null -w "HTTP %{http_code}\n" http://localhost/ || true
