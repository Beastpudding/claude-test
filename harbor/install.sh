#!/usr/bin/env bash
# Harbor 컨테이너 레지스트리 EC2 (m5.large) 일괄 프로비저닝 — Jenkins/GitLab 동형.
#
# 흐름:
#   1. .env 로드 + EKS VPC/subnet 발견
#   2. Cognito App Client (Harbor용, Confidential)
#   3. IAM Role + Instance Profile
#   4. Security Group (80, 443 from VPC)
#   5. EBS gp3 500Gi (encrypted)
#   6. user-data + harbor.yml 치환 → EC2 launch
#   7. EBS attach
#   8. internet-facing NLB (public subnets) → 80/TCP → Harbor:80
#   9. CloudFront 분배 (TLS 종단)
#  10. Cognito callback URL 갱신
#  11. Harbor REST API로 OIDC 자동 설정 (admin/initial_password로 시작)
#
# 사용:
#   ./harbor/install.sh           # 신규 설치 또는 멱등 재실행
#   ./harbor/install.sh oidc      # 이미 떠있는 Harbor에 OIDC만 설정/갱신
#   ./harbor/install.sh teardown  # 리소스 일괄 삭제

set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then echo "ERROR: .env 없음" >&2; exit 1; fi
set -o allexport; . ./.env; set +o allexport

: "${AWS_REGION:?must be set}"
: "${AWS_ACCOUNT_ID:?must be set}"
: "${EKS_CLUSTER_NAME:?must be set}"
: "${COGNITO_DOMAIN:?must be set}"
: "${COGNITO_USER_POOL_ID:?must be set}"
: "${JUPYTERHUB_ADMIN:?must be set}"

HARBOR_NAME="${HARBOR_NAME:-harbor-kbdev}"
HARBOR_INSTANCE_TYPE="${HARBOR_INSTANCE_TYPE:-m5.large}"
HARBOR_VOLUME_SIZE="${HARBOR_VOLUME_SIZE:-500}"
HARBOR_VERSION="${HARBOR_VERSION:-v2.10.0}"

# ── teardown ────────────────────────────────────────────────────
if [ "${1:-}" = "teardown" ]; then
    echo "=== Harbor 리소스 삭제 ==="
    INST=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=$HARBOR_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
    [ -n "$INST" ] && aws ec2 terminate-instances --instance-ids $INST --region "$AWS_REGION" || true

    LB=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query "LoadBalancers[?LoadBalancerName=='$HARBOR_NAME'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)
    [ -n "$LB" ] && [ "$LB" != "None" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB" --region "$AWS_REGION" || true

    EBS=$(aws ec2 describe-volumes --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=$HARBOR_NAME-data" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
    [ -n "$EBS" ] && sleep 60 && aws ec2 delete-volume --volume-id $EBS --region "$AWS_REGION" || true

    SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --filters "Name=group-name,Values=$HARBOR_NAME-sg" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
    [ -n "$SG" ] && [ "$SG" != "None" ] && aws ec2 delete-security-group --group-id "$SG" --region "$AWS_REGION" || true

    aws iam remove-role-from-instance-profile --instance-profile-name "$HARBOR_NAME-profile" --role-name "$HARBOR_NAME-role" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "$HARBOR_NAME-profile" 2>/dev/null || true
    aws iam detach-role-policy --role-name "$HARBOR_NAME-role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
    aws iam delete-role --role-name "$HARBOR_NAME-role" 2>/dev/null || true

    echo "(Cognito App Client / CloudFront은 콘솔에서 수동 삭제)"
    exit 0
fi

# ── oidc-only 모드: 이미 떠있는 Harbor에 OIDC만 설정 ───────────
if [ "${1:-}" = "oidc" ]; then
    : "${HARBOR_URL:?HARBOR_URL must be set in .env}"
    : "${HARBOR_ADMIN_PASSWORD:?must be set in .env}"
    : "${HARBOR_COGNITO_CLIENT_ID:?must be set in .env}"
    : "${HARBOR_COGNITO_CLIENT_SECRET:?must be set in .env}"

    # Harbor의 oidc_endpoint는 issuer URL (go-oidc가 /.well-known/openid-configuration 자동 append).
    # discovery URL 전체를 넣으면 go-oidc가 또 한번 append해서 404/400 발생.
    OIDC_ISSUER="https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}"

    cat > /tmp/oidc-config.json <<EOF
{
  "auth_mode": "oidc_auth",
  "oidc_name": "Cognito",
  "oidc_endpoint": "$OIDC_ISSUER",
  "oidc_client_id": "$HARBOR_COGNITO_CLIENT_ID",
  "oidc_client_secret": "$HARBOR_COGNITO_CLIENT_SECRET",
  "oidc_scope": "openid,email,profile",
  "oidc_verify_cert": true,
  "oidc_auto_onboard": true,
  "oidc_user_claim": "email",
  "oidc_admin_group": "admin",
  "oidc_groups_claim": "cognito:groups"
}
EOF
    echo "=== Harbor에 OIDC 설정 적용 ==="
    curl -fsSL -X PUT "${HARBOR_URL}/api/v2.0/configurations" \
        -u "admin:${HARBOR_ADMIN_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d @/tmp/oidc-config.json
    echo "  ✅ OIDC 설정 완료. 로그아웃 후 재로그인하면 Cognito SSO 로그인 가능."
    exit 0
fi

# ── 1. EKS VPC/subnet 발견 ──────────────────────────────────────
echo "=== Step 1: VPC/subnet 발견 ==="
VPC_ID=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)
PRIVATE_SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:karpenter.sh/discovery,Values=$EKS_CLUSTER_NAME" \
    --query 'Subnets[].SubnetId' --output text)
PRIV_LIST=($PRIVATE_SUBNETS)
HARBOR_SUBNET="${PRIV_LIST[0]}"
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" --query 'Vpcs[0].CidrBlock' --output text)
HARBOR_AZ=$(aws ec2 describe-subnets --subnet-ids "$HARBOR_SUBNET" --region "$AWS_REGION" --query 'Subnets[0].AvailabilityZone' --output text)
echo "  VPC=$VPC_ID subnet=$HARBOR_SUBNET AZ=$HARBOR_AZ"

# ── 2. Cognito App Client (Harbor용) ─────────────────────────────
echo ""
echo "=== Step 2: Cognito App Client ==="
HARBOR_CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "$COGNITO_USER_POOL_ID" --region "$AWS_REGION" \
    --query "UserPoolClients[?ClientName=='$HARBOR_NAME'].ClientId | [0]" --output text 2>/dev/null || true)

# JENKINS_URL이 있으면 그걸 기준으로 임시 callback; HARBOR_URL이 있으면 정식 사용
TEMP_CB="${HARBOR_URL:-https://placeholder.cloudfront.net}/c/oidc/callback"

if [ -z "$HARBOR_CLIENT_ID" ] || [ "$HARBOR_CLIENT_ID" = "None" ]; then
    OUT=$(aws cognito-idp create-user-pool-client --region "$AWS_REGION" \
        --user-pool-id "$COGNITO_USER_POOL_ID" \
        --client-name "$HARBOR_NAME" \
        --generate-secret \
        --allowed-o-auth-flows code \
        --allowed-o-auth-scopes openid email profile \
        --allowed-o-auth-flows-user-pool-client \
        --supported-identity-providers COGNITO \
        --callback-urls "$TEMP_CB" \
        --logout-urls "${HARBOR_URL:-https://placeholder.cloudfront.net}/" \
        --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH \
        --output json)
    HARBOR_CLIENT_ID=$(echo "$OUT" | jq -r '.UserPoolClient.ClientId')
    HARBOR_CLIENT_SECRET=$(echo "$OUT" | jq -r '.UserPoolClient.ClientSecret')
    echo "  신규: $HARBOR_CLIENT_ID"
else
    HARBOR_CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client --region "$AWS_REGION" \
        --user-pool-id "$COGNITO_USER_POOL_ID" --client-id "$HARBOR_CLIENT_ID" \
        --query 'UserPoolClient.ClientSecret' --output text)
    echo "  기존: $HARBOR_CLIENT_ID"
fi

# ── 3. IAM Role + Instance Profile ──────────────────────────────
echo ""
echo "=== Step 3: IAM Role ==="
if ! aws iam get-role --role-name "$HARBOR_NAME-role" 2>/dev/null >/dev/null; then
    aws iam create-role --role-name "$HARBOR_NAME-role" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    aws iam attach-role-policy --role-name "$HARBOR_NAME-role" \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
fi
if ! aws iam get-instance-profile --instance-profile-name "$HARBOR_NAME-profile" 2>/dev/null >/dev/null; then
    aws iam create-instance-profile --instance-profile-name "$HARBOR_NAME-profile" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$HARBOR_NAME-profile" \
        --role-name "$HARBOR_NAME-role"
    sleep 10
fi

# ── 4. Security Group ───────────────────────────────────────────
echo ""
echo "=== Step 4: SG ==="
HARBOR_SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$HARBOR_NAME-sg" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [ -z "$HARBOR_SG" ] || [ "$HARBOR_SG" = "None" ]; then
    HARBOR_SG=$(aws ec2 create-security-group --region "$AWS_REGION" \
        --group-name "$HARBOR_NAME-sg" --vpc-id "$VPC_ID" \
        --description "Harbor container registry SG" --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
        --group-id "$HARBOR_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0  # NLB가 client IP preserve
fi
echo "  SG=$HARBOR_SG"

# ── 5. EBS 500Gi gp3 ────────────────────────────────────────────
echo ""
echo "=== Step 5: EBS ==="
EBS_ID=$(aws ec2 describe-volumes --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$HARBOR_NAME-data" "Name=availability-zone,Values=$HARBOR_AZ" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
if [ -z "$EBS_ID" ]; then
    EBS_ID=$(aws ec2 create-volume --region "$AWS_REGION" \
        --availability-zone "$HARBOR_AZ" --size "$HARBOR_VOLUME_SIZE" \
        --volume-type gp3 --encrypted \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$HARBOR_NAME-data}]" \
        --query 'VolumeId' --output text)
    aws ec2 wait volume-available --volume-ids "$EBS_ID" --region "$AWS_REGION"
    echo "  신규: $EBS_ID"
else
    echo "  기존: $EBS_ID"
fi

# ── 6. harbor.yml + user-data 렌더 ───────────────────────────────
echo ""
echo "=== Step 6: 렌더 ==="
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-$(openssl rand -hex 16)}"
HARBOR_DB_PASSWORD="${HARBOR_DB_PASSWORD:-$(openssl rand -hex 16)}"
HARBOR_HOSTNAME="${HARBOR_URL#https://}"
HARBOR_HOSTNAME="${HARBOR_HOSTNAME:-placeholder.cloudfront.net}"

# user-data 렌더: 공식 harbor.yml.tmpl(EC2 내)에 우리 값 sed로 덮어쓰기.
# 직접 작성하면 Harbor 버전마다 필수 필드 차이로 prepare 실패함.
USER_DATA=$(EBS_DEVICE="/dev/nvme1n1" \
            HARBOR_VERSION_VAR="$HARBOR_VERSION" \
            HARBOR_HOSTNAME_VAR="$HARBOR_HOSTNAME" \
            HARBOR_ADMIN_PASSWORD_VAR="$HARBOR_ADMIN_PASSWORD" \
            HARBOR_DB_PASSWORD_VAR="$HARBOR_DB_PASSWORD" \
    python3 -c '
import os, sys
with open("harbor/user-data.sh") as f: s = f.read()
mapping = {
    "__EBS_DEVICE__":               os.environ["EBS_DEVICE"],
    "__HARBOR_VERSION__":           os.environ["HARBOR_VERSION_VAR"],
    "__HARBOR_HOSTNAME_VAR__":      os.environ["HARBOR_HOSTNAME_VAR"],
    "__HARBOR_ADMIN_PASSWORD_VAR__":os.environ["HARBOR_ADMIN_PASSWORD_VAR"],
    "__HARBOR_DB_PASSWORD_VAR__":   os.environ["HARBOR_DB_PASSWORD_VAR"],
}
for k,v in mapping.items(): s = s.replace(k, v)
sys.stdout.write(s)
')

# ── 7. EC2 launch ──────────────────────────────────────────────
echo ""
echo "=== Step 7: EC2 ==="
EXISTING=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$HARBOR_NAME" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)

if [ -z "$EXISTING" ]; then
    AMI=$(aws ec2 describe-images --region "$AWS_REGION" --owners amazon \
        --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)

    INST_ID=$(aws ec2 run-instances --region "$AWS_REGION" \
        --image-id "$AMI" \
        --instance-type "$HARBOR_INSTANCE_TYPE" \
        --subnet-id "$HARBOR_SUBNET" \
        --security-group-ids "$HARBOR_SG" \
        --iam-instance-profile "Name=$HARBOR_NAME-profile" \
        --user-data "$USER_DATA" \
        --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$HARBOR_NAME}]" \
        --query 'Instances[0].InstanceId' --output text)
    echo "  신규: $INST_ID"
    aws ec2 wait instance-running --instance-ids "$INST_ID" --region "$AWS_REGION"
    aws ec2 attach-volume --region "$AWS_REGION" \
        --instance-id "$INST_ID" --volume-id "$EBS_ID" --device /dev/sdf
else
    INST_ID="$EXISTING"
    echo "  기존: $INST_ID"
fi

# ── 8. internet-facing NLB ──────────────────────────────────────
echo ""
echo "=== Step 8: NLB ==="
LB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?LoadBalancerName=='$HARBOR_NAME'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)
if [ -z "$LB_ARN" ] || [ "$LB_ARN" = "None" ]; then
    PUBLIC_SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/elb,Values=1" \
        --query 'Subnets[].SubnetId' --output text)
    LB_ARN=$(aws elbv2 create-load-balancer --region "$AWS_REGION" \
        --name "$HARBOR_NAME" --type network --scheme internet-facing \
        --subnets $PUBLIC_SUBNETS \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    TG_ARN=$(aws elbv2 create-target-group --region "$AWS_REGION" \
        --name "$HARBOR_NAME-tg" --protocol TCP --port 80 --vpc-id "$VPC_ID" \
        --target-type instance --health-check-protocol HTTP --health-check-path /api/v2.0/ping \
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
✅ Harbor 1차 프로비저닝 완료

다음 수동 단계:
  1. CloudFront 분배 생성:
     - Origin: $LB_DNS (HTTP only, port 80)
     - Cache: CachingDisabled (Docker push는 큰 청크라 caching 의미 없음)
     - Origin request: AllViewer (Host 헤더 + Auth 헤더 전달 필수)
  2. CloudFront URL을 .env에 추가:
     HARBOR_URL=https://<distribution>.cloudfront.net
     HARBOR_COGNITO_CLIENT_ID=$HARBOR_CLIENT_ID
     HARBOR_COGNITO_CLIENT_SECRET=$HARBOR_CLIENT_SECRET
     HARBOR_ADMIN_PASSWORD=$HARBOR_ADMIN_PASSWORD
  3. Cognito App Client callback URL 업데이트:
     aws cognito-idp update-user-pool-client \\
       --user-pool-id $COGNITO_USER_POOL_ID \\
       --client-id $HARBOR_CLIENT_ID \\
       --callback-urls https://<distribution>.cloudfront.net/c/oidc/callback \\
       --logout-urls https://<distribution>.cloudfront.net/
  4. EC2 부팅 후 ~3분 대기 (Harbor 컨테이너 7개 다운로드/기동)
  5. ./harbor/install.sh oidc 실행 → Harbor에 OIDC 설정 자동 적용
  6. ./deploy.sh → singleuser pod의 launcher에 Harbor 카드 등장

Harbor 관리자 (첫 로그인용):
  username: admin
  password: $HARBOR_ADMIN_PASSWORD
  (OIDC 설정 후엔 admin도 OIDC로 로그인 권장)

EC2: $INST_ID
EBS: $EBS_ID
SG: $HARBOR_SG
NLB: $LB_ARN
Cognito Client: $HARBOR_CLIENT_ID
═══════════════════════════════════════════════════════════════════
EOF
