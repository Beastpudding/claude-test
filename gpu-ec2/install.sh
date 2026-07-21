#!/usr/bin/env bash
# GPU 개발 서버 (g5.xlarge + NVIDIA A10G) 프로비저닝.
# singleuser pod들이 SSH로 접속해서 GPU 작업 가능.
#
# 흐름:
#   1. .env 로드 + EKS VPC 발견
#   2. SSH keypair 생성 (gpu-ec2/keys/ 로컬 저장, 이미 있으면 재사용)
#   3. IAM Role + Instance Profile (SSM 통신)
#   4. Security Group (VPC CIDR 내부 22 허용)
#   5. EBS gp3 200Gi
#   6. DLAMI Ubuntu 22.04 최신 검색 → EC2 g5.xlarge launch (user-data)
#   7. EBS attach
#   8. K8s Secret에 SSH private key 저장 (jupyterhub namespace)
#   9. .env에 GPU_HOST 기록
#
# 사용:
#   ./gpu-ec2/install.sh           # 신규 또는 멱등
#   ./gpu-ec2/install.sh teardown  # EC2 + EBS + SG + IAM 삭제

set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then echo "ERROR: .env 없음" >&2; exit 1; fi
set -o allexport; . ./.env; set +o allexport

: "${AWS_REGION:?}"
: "${AWS_ACCOUNT_ID:?}"
: "${EKS_CLUSTER_NAME:?}"
: "${NAMESPACE:?}"

GPU_NAME="${GPU_NAME:-gpu-kbdev}"
GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g5.xlarge}"
GPU_VOLUME_SIZE="${GPU_VOLUME_SIZE:-200}"
KEY_DIR="gpu-ec2/keys"
KEY_PATH="$KEY_DIR/gpu_key"

# ── teardown ────────────────────────────────────────────────────
if [ "${1:-}" = "teardown" ]; then
    echo "=== GPU EC2 리소스 삭제 ==="
    INST=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=$GPU_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
    [ -n "$INST" ] && aws ec2 terminate-instances --instance-ids $INST --region "$AWS_REGION" || true
    EBS=$(aws ec2 describe-volumes --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=$GPU_NAME-data" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
    [ -n "$EBS" ] && sleep 60 && aws ec2 delete-volume --volume-id $EBS --region "$AWS_REGION" || true
    SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --filters "Name=group-name,Values=$GPU_NAME-sg" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
    [ -n "$SG" ] && [ "$SG" != "None" ] && aws ec2 delete-security-group --group-id "$SG" --region "$AWS_REGION" || true
    aws iam remove-role-from-instance-profile --instance-profile-name "$GPU_NAME-profile" --role-name "$GPU_NAME-role" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "$GPU_NAME-profile" 2>/dev/null || true
    aws iam detach-role-policy --role-name "$GPU_NAME-role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
    aws iam delete-role --role-name "$GPU_NAME-role" 2>/dev/null || true
    kubectl delete secret gpu-ssh-key -n "$NAMESPACE" 2>/dev/null || true
    exit 0
fi

# ── 1. VPC/subnet 발견 ──────────────────────────────────────────
echo "=== Step 1: VPC/subnet ==="
VPC_ID=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)
PRIVATE_SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:karpenter.sh/discovery,Values=$EKS_CLUSTER_NAME" \
    --query 'Subnets[].SubnetId' --output text)
PRIV_LIST=($PRIVATE_SUBNETS)
GPU_SUBNET="${PRIV_LIST[0]}"
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" --query 'Vpcs[0].CidrBlock' --output text)
GPU_AZ=$(aws ec2 describe-subnets --subnet-ids "$GPU_SUBNET" --region "$AWS_REGION" --query 'Subnets[0].AvailabilityZone' --output text)
echo "  VPC=$VPC_ID subnet=$GPU_SUBNET AZ=$GPU_AZ CIDR=$VPC_CIDR"

# ── 2. SSH keypair (생성 또는 재사용) ───────────────────────────
echo ""
echo "=== Step 2: SSH keypair ==="
mkdir -p "$KEY_DIR"
if [ ! -f "$KEY_PATH" ]; then
    ssh-keygen -t ed25519 -N "" -C "gpu-kbdev-shared" -f "$KEY_PATH"
    echo "  신규 keypair 생성: $KEY_PATH"
else
    echo "  기존 keypair 사용: $KEY_PATH"
fi
chmod 600 "$KEY_PATH"
chmod 644 "$KEY_PATH.pub"
SSH_PUB_KEY=$(cat "$KEY_PATH.pub")

# ── 3. IAM Role ─────────────────────────────────────────────────
echo ""
echo "=== Step 3: IAM Role ==="
if ! aws iam get-role --role-name "$GPU_NAME-role" 2>/dev/null >/dev/null; then
    aws iam create-role --role-name "$GPU_NAME-role" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    aws iam attach-role-policy --role-name "$GPU_NAME-role" \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
fi
if ! aws iam get-instance-profile --instance-profile-name "$GPU_NAME-profile" 2>/dev/null >/dev/null; then
    aws iam create-instance-profile --instance-profile-name "$GPU_NAME-profile" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$GPU_NAME-profile" \
        --role-name "$GPU_NAME-role"
    sleep 10
fi

# ── 4. SG ───────────────────────────────────────────────────────
echo ""
echo "=== Step 4: SG ==="
GPU_SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$GPU_NAME-sg" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [ -z "$GPU_SG" ] || [ "$GPU_SG" = "None" ]; then
    GPU_SG=$(aws ec2 create-security-group --region "$AWS_REGION" \
        --group-name "$GPU_NAME-sg" --vpc-id "$VPC_ID" \
        --description "GPU dev EC2 SG - SSH from VPC only" --query 'GroupId' --output text)
    # VPC 내부만 22 허용 (singleuser pod IP는 VPC CIDR에 포함)
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
        --group-id "$GPU_SG" --protocol tcp --port 22 --cidr "$VPC_CIDR" >/dev/null
fi
echo "  SG=$GPU_SG"

# ── 5. EBS ──────────────────────────────────────────────────────
echo ""
echo "=== Step 5: EBS ==="
EBS_ID=$(aws ec2 describe-volumes --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$GPU_NAME-data" "Name=availability-zone,Values=$GPU_AZ" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
if [ -z "$EBS_ID" ]; then
    EBS_ID=$(aws ec2 create-volume --region "$AWS_REGION" \
        --availability-zone "$GPU_AZ" --size "$GPU_VOLUME_SIZE" \
        --volume-type gp3 --encrypted \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$GPU_NAME-data}]" \
        --query 'VolumeId' --output text)
    aws ec2 wait volume-available --volume-ids "$EBS_ID" --region "$AWS_REGION"
    echo "  신규: $EBS_ID"
else
    echo "  기존: $EBS_ID"
fi

# ── 6. user-data 렌더 + EC2 launch ──────────────────────────────
echo ""
echo "=== Step 6: user-data + EC2 launch ==="
USER_DATA=$(EBS_DEVICE="/dev/nvme1n1" \
            SSH_PUB_KEY_VAR="$SSH_PUB_KEY" \
    python3 -c '
import os, sys
with open("gpu-ec2/user-data.sh") as f: s = f.read()
s = s.replace("__EBS_DEVICE__", os.environ["EBS_DEVICE"])
s = s.replace("__SSH_PUB_KEY__", os.environ["SSH_PUB_KEY_VAR"])
sys.stdout.write(s)
')

EXISTING=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$GPU_NAME" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)

if [ -z "$EXISTING" ]; then
    # DLAMI Ubuntu 22.04 최신 (NVIDIA driver + CUDA + PyTorch pre-installed)
    AMI=$(aws ec2 describe-images --region "$AWS_REGION" --owners amazon \
        --filters \
            "Name=name,Values=Deep Learning OSS Nvidia Driver AMI GPU PyTorch*Ubuntu 22.04*" \
            "Name=state,Values=available" \
            "Name=architecture,Values=x86_64" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
    [ -z "$AMI" ] || [ "$AMI" = "None" ] && {
        # fallback: 그냥 Ubuntu 22.04 (nvidia driver 없음, user-data로 설치 필요)
        AMI=$(aws ec2 describe-images --region "$AWS_REGION" --owners 099720109477 \
            --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
                      "Name=state,Values=available" \
            --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
    }
    echo "  AMI: $AMI"
    INST_ID=$(aws ec2 run-instances --region "$AWS_REGION" \
        --image-id "$AMI" \
        --instance-type "$GPU_INSTANCE_TYPE" \
        --subnet-id "$GPU_SUBNET" \
        --security-group-ids "$GPU_SG" \
        --iam-instance-profile "Name=$GPU_NAME-profile" \
        --user-data "$USER_DATA" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
        --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$GPU_NAME}]" \
        --query 'Instances[0].InstanceId' --output text)
    echo "  신규 instance: $INST_ID"
    aws ec2 wait instance-running --instance-ids "$INST_ID" --region "$AWS_REGION"
    aws ec2 attach-volume --region "$AWS_REGION" \
        --instance-id "$INST_ID" --volume-id "$EBS_ID" --device /dev/sdf
else
    INST_ID="$EXISTING"
    echo "  기존 instance: $INST_ID"
fi

# ── 7. EC2 private IP 조회 ──────────────────────────────────────
GPU_HOST=$(aws ec2 describe-instances --instance-ids "$INST_ID" --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

# ── 8. K8s Secret에 SSH 키 저장 ────────────────────────────────
echo ""
echo "=== Step 8: K8s Secret (SSH private key) ==="
kubectl create secret generic gpu-ssh-key -n "$NAMESPACE" \
    --from-file=gpu_key="$KEY_PATH" \
    --from-file=gpu_key.pub="$KEY_PATH.pub" \
    --dry-run=client -o yaml | kubectl apply -f -

# ── 9. .env 업데이트 ────────────────────────────────────────────
if grep -q "^GPU_HOST=" .env; then
    sed -i.bak "s|^GPU_HOST=.*|GPU_HOST=$GPU_HOST|" .env
else
    echo "" >> .env
    echo "# GPU 개발 서버 (g5.xlarge, gpu-ec2/install.sh)" >> .env
    echo "GPU_HOST=$GPU_HOST" >> .env
    echo "GPU_EC2_ID=$INST_ID" >> .env
fi
rm -f .env.bak

cat <<EOF

═══════════════════════════════════════════════════════════════════
✅ GPU EC2 프로비저닝 완료

EC2: $INST_ID  (private IP: $GPU_HOST)
EBS: $EBS_ID (200Gi @ /data)
SG: $GPU_SG (SSH from VPC CIDR $VPC_CIDR)

부팅 후 ~3분 대기 (user-data 실행, NVIDIA driver initialize).

singleuser pod에서 SSH로 접속:
  1) helm/values.yaml에 SSH key mount 추가 필요 (한 번만):
     - name: gpu-ssh
       secret:
         secretName: gpu-ssh-key
         defaultMode: 0600
     그리고 volumeMounts에서 /home/jovyan/.ssh/gpu_key 로 subPath 마운트
  2) 사용자 spawn 후 터미널에서:
     ssh -i ~/.ssh/gpu_key ubuntu@$GPU_HOST
  3) 팁: ~/.ssh/config에 alias:
     Host gpu
       HostName $GPU_HOST
       User ubuntu
       IdentityFile ~/.ssh/gpu_key
       StrictHostKeyChecking no
     → 이제 그냥 'ssh gpu'로 접속

주의:
  - g5.xlarge on-demand: 시간당 약 \$1.006 (월 24h × \$720)
  - 안 쓸 때는 stop:  aws ec2 stop-instances --instance-ids $INST_ID
  - 다시 시작:        aws ec2 start-instances --instance-ids $INST_ID
  - private IP 재부팅 후 유지 (Elastic IP 안 붙였지만 stop→start 시 유지됨)

═══════════════════════════════════════════════════════════════════
EOF
