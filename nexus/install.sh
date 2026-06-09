#!/usr/bin/env bash
# Nexus OSS 3 + oauth2-proxy (Cognito 게이트) — Jenkins/Harbor 동형.
#
# 흐름:
#   1. .env 로드 + VPC/subnet 발견
#   2. Cognito App Client (Nexus용, Confidential)
#   3. IAM Role + Instance Profile (SSM 통신)
#   4. SG (80 from 0.0.0.0/0 — NLB가 client IP preserve)
#   5. EBS 200Gi gp3
#   6. EC2 (m5.large) launch + EBS attach
#   7. internet-facing NLB (public subnets) → 80 → :4180 (oauth2-proxy)
#   8. 안내: CloudFront/Cognito callback 갱신은 수동
#
# 사용:
#   ./nexus/install.sh           # 신규 또는 멱등
#   ./nexus/install.sh init      # Maven/npm/PyPI proxy/hosted/group repo 일괄 생성
#   ./nexus/install.sh teardown  # 리소스 일괄 삭제

set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then echo "ERROR: .env 없음" >&2; exit 1; fi
set -o allexport; . ./.env; set +o allexport

: "${AWS_REGION:?must be set}"
: "${AWS_ACCOUNT_ID:?must be set}"
: "${EKS_CLUSTER_NAME:?must be set}"
: "${COGNITO_USER_POOL_ID:?must be set}"
: "${JUPYTERHUB_ADMIN:?must be set}"

NEXUS_NAME="${NEXUS_NAME:-nexus-kbdev}"
NEXUS_INSTANCE_TYPE="${NEXUS_INSTANCE_TYPE:-m5.large}"
NEXUS_VOLUME_SIZE="${NEXUS_VOLUME_SIZE:-200}"

# ── teardown ────────────────────────────────────────────────────
if [ "${1:-}" = "teardown" ]; then
    echo "=== Nexus 리소스 삭제 ==="
    INST=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=$NEXUS_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
    [ -n "$INST" ] && aws ec2 terminate-instances --instance-ids $INST --region "$AWS_REGION" || true
    LB=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query "LoadBalancers[?LoadBalancerName=='$NEXUS_NAME'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)
    [ -n "$LB" ] && [ "$LB" != "None" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB" --region "$AWS_REGION" || true
    EBS=$(aws ec2 describe-volumes --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=$NEXUS_NAME-data" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
    [ -n "$EBS" ] && sleep 60 && aws ec2 delete-volume --volume-id $EBS --region "$AWS_REGION" || true
    SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --filters "Name=group-name,Values=$NEXUS_NAME-sg" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
    [ -n "$SG" ] && [ "$SG" != "None" ] && aws ec2 delete-security-group --group-id "$SG" --region "$AWS_REGION" || true
    aws iam remove-role-from-instance-profile --instance-profile-name "$NEXUS_NAME-profile" --role-name "$NEXUS_NAME-role" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "$NEXUS_NAME-profile" 2>/dev/null || true
    aws iam detach-role-policy --role-name "$NEXUS_NAME-role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
    aws iam delete-role --role-name "$NEXUS_NAME-role" 2>/dev/null || true
    echo "(Cognito App Client / CloudFront은 콘솔에서 수동 삭제)"
    exit 0
fi

# ── init: Maven/npm/PyPI 저장소 생성 ────────────────────────────
if [ "${1:-}" = "init" ]; then
    : "${NEXUS_URL:?must be set in .env}"
    : "${NEXUS_NLB_DNS:?must be set in .env}"
    : "${NEXUS_ADMIN_PASSWORD:?must be set in .env (첫 부팅 후 EC2의 /nexus-data/admin.password에서 복사)}"

    # NLB 직접 (oauth2-proxy 우회) — admin REST API 호출
    BASE="http://${NEXUS_NLB_DNS}/service/rest/v1/repositories"
    AUTH="admin:${NEXUS_ADMIN_PASSWORD}"

    # 헤더는 nexus가 oauth2-proxy 없는 직접 접근 신뢰 필요 — admin 비번이면 OK
    # 단, NLB → oauth2-proxy(80) → nexus 라서 우회 불가. EC2 안에서 호출하거나 SG로 직접 :8081 열어야.
    # → SSM으로 EC2 안에서 호출
    INST_ID=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=$NEXUS_NAME" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' --output text)

    SCRIPT='set -e
# Nexus는 docker network 안에 있어 host에서 8081 직접 접근 불가.
# docker exec nexus 안에서 curl 호출.
NEXUS=http://localhost:8081/service/rest/v1
AUTH="admin:'"$NEXUS_ADMIN_PASSWORD"'"

req() {
  docker exec nexus curl -sS -u "$AUTH" -H "Content-Type: application/json" -w "%{http_code}\n" "$@"
}

echo "--- Maven Central proxy ---"
req -X POST "$NEXUS/repositories/maven/proxy" -d "{
  \"name\":\"maven-central\",
  \"online\":true,
  \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true},
  \"proxy\":{\"remoteUrl\":\"https://repo1.maven.org/maven2/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},
  \"negativeCache\":{\"enabled\":true,\"timeToLive\":1440},
  \"httpClient\":{\"blocked\":false,\"autoBlock\":true},
  \"maven\":{\"versionPolicy\":\"RELEASE\",\"layoutPolicy\":\"STRICT\",\"contentDisposition\":\"INLINE\"}
}" -o /dev/null

echo "--- Maven hosted (releases) ---"
req -X POST "$NEXUS/repositories/maven/hosted" -d "{
  \"name\":\"maven-releases\",
  \"online\":true,
  \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true,\"writePolicy\":\"ALLOW_ONCE\"},
  \"maven\":{\"versionPolicy\":\"RELEASE\",\"layoutPolicy\":\"STRICT\",\"contentDisposition\":\"INLINE\"}
}" -o /dev/null

echo "--- Maven hosted (snapshots) ---"
req -X POST "$NEXUS/repositories/maven/hosted" -d "{
  \"name\":\"maven-snapshots\",
  \"online\":true,
  \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true,\"writePolicy\":\"ALLOW\"},
  \"maven\":{\"versionPolicy\":\"SNAPSHOT\",\"layoutPolicy\":\"STRICT\",\"contentDisposition\":\"INLINE\"}
}" -o /dev/null

echo "--- Maven group (public) ---"
req -X POST "$NEXUS/repositories/maven/group" -d "{
  \"name\":\"maven-public\",
  \"online\":true,
  \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true},
  \"group\":{\"memberNames\":[\"maven-central\",\"maven-releases\",\"maven-snapshots\"]}
}" -o /dev/null

echo "--- npm proxy ---"
req -X POST "$NEXUS/repositories/npm/proxy" -d "{
  \"name\":\"npm-proxy\",
  \"online\":true,
  \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true},
  \"proxy\":{\"remoteUrl\":\"https://registry.npmjs.org\",\"contentMaxAge\":1440,\"metadataMaxAge\":1440},
  \"negativeCache\":{\"enabled\":true,\"timeToLive\":1440},
  \"httpClient\":{\"blocked\":false,\"autoBlock\":true}
}" -o /dev/null

echo "--- npm hosted ---"
req -X POST "$NEXUS/repositories/npm/hosted" -d "{
  \"name\":\"npm-internal\",
  \"online\":true,
  \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true,\"writePolicy\":\"ALLOW\"}
}" -o /dev/null

echo "--- npm group ---"
req -X POST "$NEXUS/repositories/npm/group" -d "{
  \"name\":\"npm-public\",
  \"online\":true,
  \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true},
  \"group\":{\"memberNames\":[\"npm-proxy\",\"npm-internal\"]}
}" -o /dev/null

echo "--- PyPI proxy ---"
req -X POST "$NEXUS/repositories/pypi/proxy" -d "{
  \"name\":\"pypi-proxy\",
  \"online\":true,
  \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true},
  \"proxy\":{\"remoteUrl\":\"https://pypi.org\",\"contentMaxAge\":1440,\"metadataMaxAge\":1440},
  \"negativeCache\":{\"enabled\":true,\"timeToLive\":1440},
  \"httpClient\":{\"blocked\":false,\"autoBlock\":true}
}" -o /dev/null

echo "--- PyPI hosted ---"
req -X POST "$NEXUS/repositories/pypi/hosted" -d "{
  \"name\":\"pypi-internal\",
  \"online\":true,
  \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true,\"writePolicy\":\"ALLOW\"}
}" -o /dev/null

echo "--- PyPI group ---"
req -X POST "$NEXUS/repositories/pypi/group" -d "{
  \"name\":\"pypi-public\",
  \"online\":true,
  \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true},
  \"group\":{\"memberNames\":[\"pypi-proxy\",\"pypi-internal\"]}
}" -o /dev/null

echo "--- 익명 사용자에게 모든 group repo read 권한 ---"
req -X PUT "http://localhost:8081/service/rest/v1/security/anonymous" -d "{\"enabled\":true,\"userId\":\"anonymous\",\"realmName\":\"NexusAuthorizingRealm\"}" -o /dev/null

echo "완료."
'
    SCRIPT_B64=$(echo "$SCRIPT" | base64)
    CMD=$(aws ssm send-command --region "$AWS_REGION" \
        --instance-ids "$INST_ID" \
        --document-name "AWS-RunShellScript" \
        --timeout-seconds 300 \
        --parameters "commands=[\"echo $SCRIPT_B64 | base64 -d | bash 2>&1 | tail -30\"]" \
        --query 'Command.CommandId' --output text)
    echo "  SSM command: $CMD"
    until [ "$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INST_ID" --region "$AWS_REGION" --query 'Status' --output text 2>/dev/null)" != "InProgress" ] && [ -n "$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INST_ID" --region "$AWS_REGION" --query 'Status' --output text 2>/dev/null)" ]; do
        sleep 10
    done
    aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INST_ID" --region "$AWS_REGION" \
        --query '{Status:Status,Out:StandardOutputContent}' --output json 2>&1 | tail -40
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
NEXUS_SUBNET="${PRIV_LIST[0]}"
NEXUS_AZ=$(aws ec2 describe-subnets --subnet-ids "$NEXUS_SUBNET" --region "$AWS_REGION" --query 'Subnets[0].AvailabilityZone' --output text)
echo "  VPC=$VPC_ID subnet=$NEXUS_SUBNET AZ=$NEXUS_AZ"

# ── 2. Cognito App Client ───────────────────────────────────────
echo ""
echo "=== Step 2: Cognito App Client ==="
NEXUS_CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "$COGNITO_USER_POOL_ID" --region "$AWS_REGION" \
    --query "UserPoolClients[?ClientName=='$NEXUS_NAME'].ClientId | [0]" --output text 2>/dev/null || true)
TEMP_CB="${NEXUS_URL:-https://placeholder.cloudfront.net}/oauth2/callback"
if [ -z "$NEXUS_CLIENT_ID" ] || [ "$NEXUS_CLIENT_ID" = "None" ]; then
    OUT=$(aws cognito-idp create-user-pool-client --region "$AWS_REGION" \
        --user-pool-id "$COGNITO_USER_POOL_ID" \
        --client-name "$NEXUS_NAME" \
        --generate-secret \
        --allowed-o-auth-flows code \
        --allowed-o-auth-scopes openid email profile \
        --allowed-o-auth-flows-user-pool-client \
        --supported-identity-providers COGNITO \
        --callback-urls "$TEMP_CB" \
        --logout-urls "${NEXUS_URL:-https://placeholder.cloudfront.net}/" \
        --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH \
        --output json)
    NEXUS_CLIENT_ID=$(echo "$OUT" | jq -r '.UserPoolClient.ClientId')
    NEXUS_CLIENT_SECRET=$(echo "$OUT" | jq -r '.UserPoolClient.ClientSecret')
    echo "  신규: $NEXUS_CLIENT_ID"
else
    NEXUS_CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client --region "$AWS_REGION" \
        --user-pool-id "$COGNITO_USER_POOL_ID" --client-id "$NEXUS_CLIENT_ID" \
        --query 'UserPoolClient.ClientSecret' --output text)
    echo "  기존: $NEXUS_CLIENT_ID"
fi

# ── 3. IAM Role ─────────────────────────────────────────────────
echo ""
echo "=== Step 3: IAM Role ==="
if ! aws iam get-role --role-name "$NEXUS_NAME-role" 2>/dev/null >/dev/null; then
    aws iam create-role --role-name "$NEXUS_NAME-role" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    aws iam attach-role-policy --role-name "$NEXUS_NAME-role" \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
fi
if ! aws iam get-instance-profile --instance-profile-name "$NEXUS_NAME-profile" 2>/dev/null >/dev/null; then
    aws iam create-instance-profile --instance-profile-name "$NEXUS_NAME-profile" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$NEXUS_NAME-profile" \
        --role-name "$NEXUS_NAME-role"
    sleep 10
fi

# ── 4. SG ───────────────────────────────────────────────────────
echo ""
echo "=== Step 4: SG ==="
NEXUS_SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$NEXUS_NAME-sg" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [ -z "$NEXUS_SG" ] || [ "$NEXUS_SG" = "None" ]; then
    NEXUS_SG=$(aws ec2 create-security-group --region "$AWS_REGION" \
        --group-name "$NEXUS_NAME-sg" --vpc-id "$VPC_ID" \
        --description "Nexus OSS SG" --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
        --group-id "$NEXUS_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0
fi
echo "  SG=$NEXUS_SG"

# ── 5. EBS ──────────────────────────────────────────────────────
echo ""
echo "=== Step 5: EBS ==="
EBS_ID=$(aws ec2 describe-volumes --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$NEXUS_NAME-data" "Name=availability-zone,Values=$NEXUS_AZ" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
if [ -z "$EBS_ID" ]; then
    EBS_ID=$(aws ec2 create-volume --region "$AWS_REGION" \
        --availability-zone "$NEXUS_AZ" --size "$NEXUS_VOLUME_SIZE" \
        --volume-type gp3 --encrypted \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$NEXUS_NAME-data}]" \
        --query 'VolumeId' --output text)
    aws ec2 wait volume-available --volume-ids "$EBS_ID" --region "$AWS_REGION"
    echo "  신규: $EBS_ID"
else
    echo "  기존: $EBS_ID"
fi

# ── 6. user-data 렌더 ────────────────────────────────────────────
# 단일 docker run + systemd 방식 (compose 없음, oauth2-proxy 없음 — 익명 접근)
echo ""
echo "=== Step 6: 렌더 ==="
USER_DATA=$(EBS_DEVICE="/dev/nvme1n1" \
    python3 -c '
import os, sys
with open("nexus/user-data.sh") as f: s = f.read()
s = s.replace("__EBS_DEVICE__", os.environ["EBS_DEVICE"])
sys.stdout.write(s)
')

# ── 7. EC2 ─────────────────────────────────────────────────────
echo ""
echo "=== Step 7: EC2 ==="
EXISTING=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$NEXUS_NAME" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
if [ -z "$EXISTING" ]; then
    AMI=$(aws ec2 describe-images --region "$AWS_REGION" --owners amazon \
        --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
    INST_ID=$(aws ec2 run-instances --region "$AWS_REGION" \
        --image-id "$AMI" \
        --instance-type "$NEXUS_INSTANCE_TYPE" \
        --subnet-id "$NEXUS_SUBNET" \
        --security-group-ids "$NEXUS_SG" \
        --iam-instance-profile "Name=$NEXUS_NAME-profile" \
        --user-data "$USER_DATA" \
        --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NEXUS_NAME}]" \
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
    --query "LoadBalancers[?LoadBalancerName=='$NEXUS_NAME'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)
if [ -z "$LB_ARN" ] || [ "$LB_ARN" = "None" ]; then
    PUBLIC_SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/elb,Values=1" \
        --query 'Subnets[].SubnetId' --output text)
    LB_ARN=$(aws elbv2 create-load-balancer --region "$AWS_REGION" \
        --name "$NEXUS_NAME" --type network --scheme internet-facing \
        --subnets $PUBLIC_SUBNETS \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    TG_ARN=$(aws elbv2 create-target-group --region "$AWS_REGION" \
        --name "$NEXUS_NAME-tg" --protocol TCP --port 80 --vpc-id "$VPC_ID" \
        --target-type instance --health-check-protocol HTTP \
        --health-check-path /service/rest/v1/status \
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

cat <<EOF

═══════════════════════════════════════════════════════════════════
✅ Nexus 1차 프로비저닝 완료

다음 수동 단계:
  1. CloudFront 분배 생성 (Jenkins/Harbor와 동일 설정):
     - Origin: $LB_DNS (http-only, 80)
     - Cache: CachingDisabled
     - Origin request: AllViewer
  2. .env 추가:
     NEXUS_URL=https://<distribution>.cloudfront.net
     NEXUS_COGNITO_CLIENT_ID=$NEXUS_CLIENT_ID
     NEXUS_COGNITO_CLIENT_SECRET=$NEXUS_CLIENT_SECRET
     NEXUS_COOKIE_SECRET=$COOKIE_SECRET
     NEXUS_NLB_DNS=$LB_DNS
     NEXUS_ADMIN_PASSWORD=<EC2의 /nexus-data/admin.password 첫 부팅 후 복사>
  3. Cognito callback 갱신:
     aws cognito-idp update-user-pool-client \\
       --user-pool-id $COGNITO_USER_POOL_ID \\
       --client-id $NEXUS_CLIENT_ID \\
       --callback-urls https://<distribution>.cloudfront.net/oauth2/callback \\
       --logout-urls https://<distribution>.cloudfront.net/
  4. ./nexus/install.sh 재실행 → docker-compose에 정식 NEXUS_URL/COOKIE_SECRET 반영
  5. EC2 부팅 후 ~7분 대기 (nexus 첫 기동 무거움)
  6. ./nexus/install.sh init → Maven/npm/PyPI proxy/hosted/group repo 일괄 생성
  7. ./deploy.sh → launcher에 Nexus 카드 등장

EC2: $INST_ID
EBS: $EBS_ID
SG: $NEXUS_SG
NLB: $LB_ARN
Cognito Client: $NEXUS_CLIENT_ID
═══════════════════════════════════════════════════════════════════
EOF
