#!/usr/bin/env bash
# Jenkins EC2 (m5.large) 운영 환경 일괄 프로비저닝 — GitLab과 동형.
#
# 흐름:
#   1. .env 로드 + EKS VPC/subnet/SG 자동 발견
#   2. Cognito App Client (Jenkins용, Confidential) 생성
#   3. IAM Role + Instance Profile 생성 (ECR 읽기, S3 백업 가능)
#   4. Security Group: NLB(80) → Jenkins(8080), 같은 VPC 내 SSM 접근
#   5. EBS gp3 200Gi 생성
#   6. casc.yaml.tmpl + user-data.sh 치환 → EC2 launch
#   7. EBS attach
#   8. internal NLB → 80/TCP → Jenkins:8080
#   9. CloudFront distribution (NLB origin, WAF 부착은 수동 — GitLab IP allow-list 재사용)
#  10. .env에 JENKINS_URL 자동 기록
#
# 사용:
#   ./jenkins/install.sh           # 신규 설치
#   ./jenkins/install.sh teardown  # 리소스 일괄 삭제

set -euo pipefail
cd "$(dirname "$0")/.."

# ── .env 로드 ────────────────────────────────────────────────────
if [ ! -f .env ]; then
    echo "ERROR: .env 파일이 없습니다." >&2; exit 1
fi
set -o allexport; . ./.env; set +o allexport

: "${AWS_REGION:?must be set in .env}"
: "${AWS_ACCOUNT_ID:?must be set in .env}"
: "${EKS_CLUSTER_NAME:?must be set in .env}"
: "${COGNITO_DOMAIN:?must be set in .env}"
: "${JUPYTERHUB_ADMIN:?must be set in .env}"

JENKINS_NAME="${JENKINS_NAME:-jenkins-kbdev}"
JENKINS_INSTANCE_TYPE="${JENKINS_INSTANCE_TYPE:-m5.large}"
JENKINS_VOLUME_SIZE="${JENKINS_VOLUME_SIZE:-200}"
COGNITO_USER_POOL_ID="${COGNITO_USER_POOL_ID:-$(echo "$COGNITO_DOMAIN" | sed -E 's|.*amazoncognito\.com.*||; s|https://||; s|\..*||' )}"

# Cognito User Pool ID 자동 추출 (.env에 명시 안 됐을 때): describe-user-pool 호출 필요
if [ -z "${COGNITO_USER_POOL_ID:-}" ] || ! [[ "$COGNITO_USER_POOL_ID" =~ ^[a-z0-9-]+_[A-Za-z0-9]+$ ]]; then
    POOL_DOMAIN=$(echo "$COGNITO_DOMAIN" | sed -E 's|https?://([^.]+)\..*|\1|')
    COGNITO_USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 50 --region "$AWS_REGION" \
        --query "UserPools[?contains(Name,'$POOL_DOMAIN') || contains('$POOL_DOMAIN',Name)].Id | [0]" --output text 2>/dev/null || true)
    if [ -z "$COGNITO_USER_POOL_ID" ] || [ "$COGNITO_USER_POOL_ID" = "None" ]; then
        echo "ERROR: COGNITO_USER_POOL_ID를 자동 발견 못함. .env에 직접 추가해주세요." >&2
        exit 1
    fi
fi
echo "Cognito User Pool: $COGNITO_USER_POOL_ID"

# ── teardown 모드 ───────────────────────────────────────────────
if [ "${1:-}" = "teardown" ]; then
    echo "=== Jenkins 리소스 삭제 ==="
    INST_ID=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=$JENKINS_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
    [ -n "$INST_ID" ] && aws ec2 terminate-instances --instance-ids $INST_ID --region "$AWS_REGION" || true

    LB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query "LoadBalancers[?LoadBalancerName=='$JENKINS_NAME'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)
    [ -n "$LB_ARN" ] && [ "$LB_ARN" != "None" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN" --region "$AWS_REGION" || true

    EBS_ID=$(aws ec2 describe-volumes --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=$JENKINS_NAME-home" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
    [ -n "$EBS_ID" ] && sleep 60 && aws ec2 delete-volume --volume-id $EBS_ID --region "$AWS_REGION" || true

    SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --filters "Name=group-name,Values=$JENKINS_NAME-sg" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
    [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ] && aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" || true

    aws iam remove-role-from-instance-profile --instance-profile-name "$JENKINS_NAME-profile" --role-name "$JENKINS_NAME-role" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "$JENKINS_NAME-profile" 2>/dev/null || true
    aws iam detach-role-policy --role-name "$JENKINS_NAME-role" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly 2>/dev/null || true
    aws iam detach-role-policy --role-name "$JENKINS_NAME-role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
    aws iam delete-role --role-name "$JENKINS_NAME-role" 2>/dev/null || true

    echo "(Cognito App Client / CloudFront / WAF은 콘솔에서 수동 삭제)"
    exit 0
fi

# ── 1. EKS에서 VPC/subnet/SG 발견 ───────────────────────────────
echo "=== Step 1: EKS VPC/subnet/SG 발견 ==="
VPC_ID=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)
EKS_SG=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

# Karpenter discovery tag로 private subnet 식별 (GitLab과 동일)
PRIVATE_SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:karpenter.sh/discovery,Values=$EKS_CLUSTER_NAME" \
    --query 'Subnets[].SubnetId' --output text)
PRIVATE_SUBNET_LIST=($PRIVATE_SUBNETS)
JENKINS_SUBNET="${PRIVATE_SUBNET_LIST[0]}"   # 첫 AZ에 controller 배치
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" --query 'Vpcs[0].CidrBlock' --output text)
JENKINS_AZ=$(aws ec2 describe-subnets --subnet-ids "$JENKINS_SUBNET" --region "$AWS_REGION" --query 'Subnets[0].AvailabilityZone' --output text)
echo "  VPC=$VPC_ID  subnet=$JENKINS_SUBNET  AZ=$JENKINS_AZ  CIDR=$VPC_CIDR"

# ── 2. Cognito App Client (Jenkins용) ────────────────────────────
echo ""
echo "=== Step 2: Cognito App Client (Jenkins) ==="
# 이미 존재하면 재사용
JENKINS_CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "$COGNITO_USER_POOL_ID" --region "$AWS_REGION" \
    --query "UserPoolClients[?ClientName=='$JENKINS_NAME'].ClientId | [0]" --output text 2>/dev/null || true)

# JENKINS_URL이 아직 결정 안 됐으면 임시값으로 client 만들고, NLB/CloudFront 만든 후 update.
# 첫 실행 시엔 callback이 placeholder. 두 번째 실행에서 진짜 URL로 교체.
TEMP_CALLBACK="https://placeholder.cloudfront.net/securityRealm/finishLogin"

if [ -z "$JENKINS_CLIENT_ID" ] || [ "$JENKINS_CLIENT_ID" = "None" ]; then
    OUT=$(aws cognito-idp create-user-pool-client --region "$AWS_REGION" \
        --user-pool-id "$COGNITO_USER_POOL_ID" \
        --client-name "$JENKINS_NAME" \
        --generate-secret \
        --allowed-o-auth-flows code \
        --allowed-o-auth-scopes openid email profile \
        --allowed-o-auth-flows-user-pool-client \
        --supported-identity-providers COGNITO \
        --callback-urls "$TEMP_CALLBACK" \
        --logout-urls "https://placeholder.cloudfront.net/" \
        --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH \
        --output json)
    JENKINS_CLIENT_ID=$(echo "$OUT" | jq -r '.UserPoolClient.ClientId')
    JENKINS_CLIENT_SECRET=$(echo "$OUT" | jq -r '.UserPoolClient.ClientSecret')
    echo "  신규 생성: $JENKINS_CLIENT_ID"
else
    JENKINS_CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client --region "$AWS_REGION" \
        --user-pool-id "$COGNITO_USER_POOL_ID" --client-id "$JENKINS_CLIENT_ID" \
        --query 'UserPoolClient.ClientSecret' --output text)
    echo "  기존 사용: $JENKINS_CLIENT_ID"
fi

# ── 3. IAM Role + Instance Profile ──────────────────────────────
echo ""
echo "=== Step 3: IAM Role/Instance Profile ==="
if ! aws iam get-role --role-name "$JENKINS_NAME-role" 2>/dev/null >/dev/null; then
    aws iam create-role --role-name "$JENKINS_NAME-role" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    aws iam attach-role-policy --role-name "$JENKINS_NAME-role" \
        --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
    aws iam attach-role-policy --role-name "$JENKINS_NAME-role" \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
fi
if ! aws iam get-instance-profile --instance-profile-name "$JENKINS_NAME-profile" 2>/dev/null >/dev/null; then
    aws iam create-instance-profile --instance-profile-name "$JENKINS_NAME-profile" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$JENKINS_NAME-profile" \
        --role-name "$JENKINS_NAME-role"
    sleep 10   # propagation
fi

# ── 4. Security Group ───────────────────────────────────────────
echo ""
echo "=== Step 4: Security Group ==="
JENKINS_SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$JENKINS_NAME-sg" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [ -z "$JENKINS_SG" ] || [ "$JENKINS_SG" = "None" ]; then
    JENKINS_SG=$(aws ec2 create-security-group --region "$AWS_REGION" \
        --group-name "$JENKINS_NAME-sg" --vpc-id "$VPC_ID" \
        --description "Jenkins controller SG" \
        --query 'GroupId' --output text)
    # 같은 VPC 내에서 8080 + 50000 허용 (NLB → Jenkins, agent → controller)
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
        --group-id "$JENKINS_SG" --protocol tcp --port 8080 --cidr "$VPC_CIDR"
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
        --group-id "$JENKINS_SG" --protocol tcp --port 50000 --cidr "$VPC_CIDR"
fi
echo "  SG=$JENKINS_SG"

# ── 5. EBS 200Gi gp3 ────────────────────────────────────────────
echo ""
echo "=== Step 5: EBS volume ==="
EBS_ID=$(aws ec2 describe-volumes --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$JENKINS_NAME-home" "Name=availability-zone,Values=$JENKINS_AZ" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
if [ -z "$EBS_ID" ]; then
    EBS_ID=$(aws ec2 create-volume --region "$AWS_REGION" \
        --availability-zone "$JENKINS_AZ" --size "$JENKINS_VOLUME_SIZE" \
        --volume-type gp3 --encrypted \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$JENKINS_NAME-home}]" \
        --query 'VolumeId' --output text)
    echo "  신규 생성: $EBS_ID"
    aws ec2 wait volume-available --volume-ids "$EBS_ID" --region "$AWS_REGION"
else
    echo "  기존 사용: $EBS_ID"
fi

# ── 6. user-data + casc 치환 ────────────────────────────────────
echo ""
echo "=== Step 6: user-data/casc 치환 ==="
# Escape-hatch password (Cognito 장애 시 admin/이 비번으로 로그인 가능)
JENKINS_ESCAPE_HATCH_PASSWORD="${JENKINS_ESCAPE_HATCH_PASSWORD:-$(openssl rand -hex 16)}"

# casc.yaml 렌더 (JENKINS_URL은 NLB 만든 후 두 번째 단계에서 update)
JENKINS_URL_TMP="${JENKINS_URL:-https://placeholder.cloudfront.net}"
# Cognito OIDC discovery는 hosted-UI 도메인이 아닌 IdP 엔드포인트에 있음.
COGNITO_OIDC_DISCOVERY_URL="https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}/.well-known/openid-configuration"

CASC_RENDERED=$(sed \
    -e "s|__COGNITO_CLIENT_ID__|$JENKINS_CLIENT_ID|g" \
    -e "s|__COGNITO_CLIENT_SECRET__|$JENKINS_CLIENT_SECRET|g" \
    -e "s|__COGNITO_DOMAIN__|$COGNITO_DOMAIN|g" \
    -e "s|__COGNITO_OIDC_DISCOVERY_URL__|$COGNITO_OIDC_DISCOVERY_URL|g" \
    -e "s|__JENKINS_URL__|$JENKINS_URL_TMP|g" \
    -e "s|__JENKINS_ADMIN__|$JUPYTERHUB_ADMIN|g" \
    -e "s|__JENKINS_ESCAPE_HATCH_PASSWORD__|$JENKINS_ESCAPE_HATCH_PASSWORD|g" \
    -e "s|__GITLAB_TOKEN__|${GITLAB_TOKEN:-}|g" \
    jenkins/casc.yaml.tmpl)

# user-data 렌더 — Python으로 multi-line 안전하게 치환
# (awk -v 는 newline 못 받음, sed는 escape 지옥)
USER_DATA=$(EBS_DEVICE="/dev/nvme1n1" \
            JENKINS_ADMIN_VAR="$JUPYTERHUB_ADMIN" \
            PLUGINS_LIST="$(cat jenkins/plugins.txt)" \
            CASC_CONTENT="$CASC_RENDERED" \
            GROOVY_ITEM_ISOLATION="$(cat jenkins/init.groovy.d/00-item-isolation.groovy)" \
    python3 -c '
import os, sys
with open("jenkins/user-data.sh") as f: s = f.read()
for k in ("EBS_DEVICE","PLUGINS_LIST","CASC_CONTENT","GROOVY_ITEM_ISOLATION"):
    s = s.replace(f"__{k}__", os.environ[k])
s = s.replace("__JENKINS_ADMIN__", os.environ["JENKINS_ADMIN_VAR"])
sys.stdout.write(s)
')

# ── 7. EC2 launch ──────────────────────────────────────────────
echo ""
echo "=== Step 7: EC2 launch ==="
EXISTING_INST=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$JENKINS_NAME" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)

if [ -z "$EXISTING_INST" ]; then
    # Amazon Linux 2023 AMI (latest)
    AMI_ID=$(aws ec2 describe-images --region "$AWS_REGION" \
        --owners amazon \
        --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
    echo "  AMI: $AMI_ID"

    INST_ID=$(aws ec2 run-instances --region "$AWS_REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$JENKINS_INSTANCE_TYPE" \
        --subnet-id "$JENKINS_SUBNET" \
        --security-group-ids "$JENKINS_SG" \
        --iam-instance-profile "Name=$JENKINS_NAME-profile" \
        --user-data "$USER_DATA" \
        --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$JENKINS_NAME}]" \
        --query 'Instances[0].InstanceId' --output text)
    echo "  신규 instance: $INST_ID"
    aws ec2 wait instance-running --instance-ids "$INST_ID" --region "$AWS_REGION"
    # EBS attach
    aws ec2 attach-volume --region "$AWS_REGION" \
        --instance-id "$INST_ID" --volume-id "$EBS_ID" --device /dev/sdf
else
    INST_ID="$EXISTING_INST"
    echo "  기존 instance: $INST_ID"
fi

# ── 8. NLB (internal) ───────────────────────────────────────────
echo ""
echo "=== Step 8: internal NLB ==="
LB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?LoadBalancerName=='$JENKINS_NAME'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)
if [ -z "$LB_ARN" ] || [ "$LB_ARN" = "None" ]; then
    # internet-facing — CloudFront origin이 되려면 public이어야 함.
    # NLB만 public subnet에 두고 target(Jenkins EC2)는 private 유지.
    PUBLIC_SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/elb,Values=1" \
        --query 'Subnets[].SubnetId' --output text)
    LB_ARN=$(aws elbv2 create-load-balancer --region "$AWS_REGION" \
        --name "$JENKINS_NAME" --type network --scheme internet-facing \
        --subnets $PUBLIC_SUBNETS \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    TG_ARN=$(aws elbv2 create-target-group --region "$AWS_REGION" \
        --name "$JENKINS_NAME-tg" --protocol TCP --port 8080 --vpc-id "$VPC_ID" \
        --target-type instance --health-check-protocol HTTP --health-check-path /login \
        --query 'TargetGroups[0].TargetGroupArn' --output text)
    aws elbv2 register-targets --region "$AWS_REGION" \
        --target-group-arn "$TG_ARN" --targets "Id=$INST_ID"
    aws elbv2 create-listener --region "$AWS_REGION" \
        --load-balancer-arn "$LB_ARN" --protocol TCP --port 80 \
        --default-actions "Type=forward,TargetGroupArn=$TG_ARN" >/dev/null
fi
LB_DNS=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --load-balancer-arns "$LB_ARN" --query 'LoadBalancers[0].DNSName' --output text)
echo "  NLB DNS: $LB_DNS"

# ── 9. 안내 ─────────────────────────────────────────────────────
cat <<EOF

═══════════════════════════════════════════════════════════════════
✅ Jenkins 1차 프로비저닝 완료

다음 수동 단계 (GitLab과 동일 — CloudFront/WAF는 콘솔):
  1. CloudFront 분배 생성:
     - Origin: $LB_DNS (HTTP only, port 80)
     - Cache: CachingDisabled
     - Origin request: AllViewer (Host 헤더 전달 필수)
  2. GitLab에 부착된 WAF Web ACL을 이 분배에도 attach (IP allow-list 공유)
  3. CloudFront URL을 .env에 추가:
     JENKINS_URL=https://<distribution>.cloudfront.net
  4. Cognito App Client callback 업데이트 (콘솔 또는 CLI):
     aws cognito-idp update-user-pool-client \\
       --user-pool-id $COGNITO_USER_POOL_ID \\
       --client-id $JENKINS_CLIENT_ID \\
       --callback-urls https://<distribution>.cloudfront.net/securityRealm/finishLogin \\
       --logout-urls https://<distribution>.cloudfront.net/
  5. ./jenkins/install.sh 재실행 → casc.yaml의 JENKINS_URL이 정식 URL로 갱신
  6. ./deploy.sh 다시 실행 → singleuser pod이 JENKINS_URL 환경변수 받음 → 런처에 Jenkins 카드 표시

Escape-hatch admin (Cognito 장애 시):
  username: admin
  password: $JENKINS_ESCAPE_HATCH_PASSWORD
  → 위 비번을 .env의 JENKINS_ESCAPE_HATCH_PASSWORD에 기록해두세요.

EC2 instance: $INST_ID
EBS: $EBS_ID
SG: $JENKINS_SG
NLB: $LB_ARN
═══════════════════════════════════════════════════════════════════
EOF
