#!/bin/bash
# EC2 cloud-init: EBS 마운트 + shared ubuntu 계정에 SSH pubkey 등록.
# DLAMI(Deep Learning AMI Ubuntu 22.04)는 NVIDIA driver + CUDA + PyTorch/TF 이미 설치됨.
set -euxo pipefail

EBS_DEVICE="__EBS_DEVICE__"                # ex) /dev/nvme1n1
SSH_PUB_KEY="__SSH_PUB_KEY__"              # single-line ssh-ed25519 AAAAC3... comment

# ── EBS 마운트 (/data) ──────────────────────────────────────────
mkdir -p /data
if ! blkid "${EBS_DEVICE}" >/dev/null 2>&1; then
    mkfs -t ext4 "${EBS_DEVICE}"
fi
if ! grep -q "${EBS_DEVICE}" /etc/fstab; then
    echo "${EBS_DEVICE}  /data  ext4  defaults,nofail  0  2" >> /etc/fstab
fi
mountpoint -q /data || mount /data
chown -R ubuntu:ubuntu /data

# ── SSH pubkey 등록 (기존 keys 유지 + 우리 key 추가, 중복 방지) ──
mkdir -p /home/ubuntu/.ssh
chmod 700 /home/ubuntu/.ssh
touch /home/ubuntu/.ssh/authorized_keys
if ! grep -qF "${SSH_PUB_KEY}" /home/ubuntu/.ssh/authorized_keys; then
    echo "${SSH_PUB_KEY}" >> /home/ubuntu/.ssh/authorized_keys
fi
chmod 600 /home/ubuntu/.ssh/authorized_keys
chown -R ubuntu:ubuntu /home/ubuntu/.ssh

# ── 유용한 편의 tools (DLAMI에 대부분 있음) ─────────────────────
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    tmux htop vim jq unzip tree ncdu \
    || true

# ── GPU 정상 인식 검증 ─────────────────────────────────────────
nvidia-smi > /var/log/nvidia-smi-boot.log 2>&1 || true

# ── /data에 사용자 프로젝트 폴더 예시 ──────────────────────────
sudo -u ubuntu mkdir -p /data/projects /data/datasets /data/models
