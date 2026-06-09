#!/bin/bash
# EC2 user-data: Amazon Linux 2023에서 Jenkins LTS 설치 + EBS 마운트 + plugins + casc 적용.
# install.sh가 cloud-init userdata로 전달하기 전, 아래 __VAR__ 들을 sed로 치환함.
set -euxo pipefail

EBS_DEVICE="__EBS_DEVICE__"          # ex) /dev/nvme1n1
JENKINS_ADMIN="__JENKINS_ADMIN__"     # email of escape-hatch admin

# ── EBS 마운트 (/var/lib/jenkins) ───────────────────────────────
mkdir -p /var/lib/jenkins
# 첫 부팅이면 ext4 포맷
if ! blkid "${EBS_DEVICE}" >/dev/null 2>&1; then
    mkfs -t ext4 "${EBS_DEVICE}"
fi
# fstab 중복 방지
if ! grep -q "${EBS_DEVICE}" /etc/fstab; then
    echo "${EBS_DEVICE}  /var/lib/jenkins  ext4  defaults,nofail  0  2" >> /etc/fstab
fi
# 이미 마운트돼있으면 skip
mountpoint -q /var/lib/jenkins || mount /var/lib/jenkins

# ── Java 21 (Jenkins LTS 권장) + git + util ─────────────────────
# AL2023의 curl-minimal과 dnf의 curl이 충돌하므로 --allowerasing으로 교체.
dnf install -y --allowerasing java-21-amazon-corretto-headless git curl wget unzip jq

# ── Jenkins LTS 저장소 + 설치 ────────────────────────────────────
wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
dnf install -y jenkins

# 권한 (EBS 마운트로 인해 root:root 일 수 있음)
chown -R jenkins:jenkins /var/lib/jenkins
chmod 750 /var/lib/jenkins

# ── 플러그인 설치 (jenkins-plugin-cli) ──────────────────────────
PLUGIN_DIR=/var/lib/jenkins/plugins
mkdir -p "$PLUGIN_DIR"

# jenkins-plugin-cli 다운로드
PLUGIN_CLI=/usr/local/bin/jenkins-plugin-cli.jar
curl -fsSL -o "$PLUGIN_CLI" \
    https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.13.0/jenkins-plugin-manager-2.13.0.jar

# plugins.txt 다운로드 (install.sh가 S3나 inline로 전달)
cat > /tmp/plugins.txt <<'PLUGINS_EOF'
__PLUGINS_LIST__
PLUGINS_EOF

# 플러그인 설치 (의존성 자동 해결)
java -jar "$PLUGIN_CLI" \
    --war /usr/share/java/jenkins.war \
    --plugin-file /tmp/plugins.txt \
    --plugin-download-directory "$PLUGIN_DIR"

chown -R jenkins:jenkins "$PLUGIN_DIR"

# ── JCasC 설정 파일 배치 ─────────────────────────────────────────
mkdir -p /var/lib/jenkins/casc_configs
cat > /var/lib/jenkins/casc_configs/jenkins.yaml <<'CASC_EOF'
__CASC_CONTENT__
CASC_EOF
chown -R jenkins:jenkins /var/lib/jenkins/casc_configs

# ── init.groovy.d 스크립트 배치 (Item 격리 listener 등) ────────────
mkdir -p /var/lib/jenkins/init.groovy.d
cat > /var/lib/jenkins/init.groovy.d/00-item-isolation.groovy <<'GROOVY_EOF'
__GROOVY_ITEM_ISOLATION__
GROOVY_EOF
chown -R jenkins:jenkins /var/lib/jenkins/init.groovy.d

# ── 초기 설정 마법사 skip + JCasC 경로 + Java opts ──────────────
mkdir -p /etc/sysconfig
cat > /etc/sysconfig/jenkins <<'EOF'
JENKINS_HOME=/var/lib/jenkins
JENKINS_USER=jenkins
JENKINS_PORT=8080
JENKINS_AGENT_PORT=50000
JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Dcasc.jenkins.config=/var/lib/jenkins/casc_configs/jenkins.yaml"
EOF

# systemd unit override (Amazon Linux의 jenkins.service는 EnvironmentFile을 안 읽으므로 강제)
mkdir -p /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf <<'EOF'
[Service]
EnvironmentFile=/etc/sysconfig/jenkins
Environment="JAVA_OPTS=-Djenkins.install.runSetupWizard=false -Dcasc.jenkins.config=/var/lib/jenkins/casc_configs/jenkins.yaml"
EOF

systemctl daemon-reload
systemctl enable jenkins
systemctl start jenkins
