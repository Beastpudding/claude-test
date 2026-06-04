# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

JupyterHub on AWS EKS branded as "Virtual AI 센터". Provides multi-user Jupyter notebooks with integrated web-based VS Code (Code-Server 4.95.3), Docker-in-Docker, pre-installed VS Code extensions (Claude Code), and per-user Bedrock access via LiteLLM. Auth via AWS Cognito User Pool (NativeAuthenticator fallback).

## Build and Deploy Commands

```bash
# Full deployment: build images → push to ECR → IRSA → secrets →
# hub-templates ConfigMap → Karpenter NodePool → Postgres → LiteLLM →
# helm upgrade --install
./deploy.sh

# Build singleuser image only (amd64 — EKS nodes are t3.medium)
docker build -f Dockerfile.codeserver -t codeserver-kbdev:local \
  --build-arg CODE_VERSION=4.95.3 --build-arg TARGETARCH=amd64 .

# Build hub image only
docker build -f Dockerfile.jupyterhub -t jupyterhub-hub:local .

# Check deployed pods
kubectl get pods -n jupyterhub

# View hub logs
kubectl logs -n jupyterhub -l component=hub -f

# Uninstall
helm uninstall jupyterhub -n jupyterhub
```

There is no test suite or linter — this is an infrastructure/deployment project.

## Architecture

**Kubernetes (EKS) deployment via zero-to-jupyterhub Helm chart:**

1. **Hub pod** (`Dockerfile.jupyterhub`) — Runs JupyterHub with KubeSpawner. Built from `quay.io/jupyterhub/k8s-hub` with `oauthenticator` (Cognito OIDC) + `nativeauthenticator` (offline fallback) added. Spawns per-user pods on demand.

2. **Singleuser pods** (`Dockerfile.codeserver`) — Spawned per user from `codeserver-kbdev` image. Based on `jupyter/base-notebook:python-3.12`. Includes Code-Server, Docker-in-Docker (dockerd via supervisord), Claude Code VSIX with OAuth patch, and the custom launcher page.

3. **Proxy pod** — Managed by Helm chart (configurable-http-proxy). Exposed via AWS NLB LoadBalancer service.

4. **LiteLLM proxy + Postgres** (`k8s/litellm.yaml`, `k8s/postgres.yaml`) — Per-user virtual API keys → Bedrock via IRSA. Postgres backs spend/usage logs (Admin UI at `/ui` after `kubectl port-forward`).

**Key data flow:** Hub listens on port 8000 (proxy) and 8081 (internal API). When a user logs in via Cognito, `pre_spawn_hook` issues/reuses a LiteLLM virtual key (stored as `litellm-vkey-<username>` secret) and injects it as `ANTHROPIC_API_KEY`. KubeSpawner creates a singleuser Pod in the `jupyterhub` namespace. User data persists in EBS-backed PVCs (`gp2` StorageClass).

## Key Configuration Files

- **`helm/values.yaml`** — All JupyterHub Helm chart settings: spawner, auth (Cognito), storage, images, branding/templates, resource limits, postStart hook.
- **`k8s/litellm.yaml`** — LiteLLM proxy: ServiceAccount (IRSA), ConfigMap (Bedrock model list), Deployment, Service.
- **`k8s/postgres.yaml`** — Postgres StatefulSet backing LiteLLM (spend logs, virtual keys).
- **`k8s/hub-rbac.yaml`** — Hub ServiceAccount permissions (create per-user LiteLLM key secrets).
- **`k8s/templates/`** — Custom Jinja2 templates (page/spawn/login) → `hub-templates` ConfigMap → mounted at `/etc/jupyterhub/custom-templates/`.
- **`k8s/lambdas/pre_signup.py`** — Cognito Pre Sign-up Lambda trigger.
- **`Dockerfile.codeserver`** — Singleuser image: Code-Server, DinD, Claude Code VSIX + OAuth patch, native binary, Python 3.12.
- **`Dockerfile.jupyterhub`** — Hub image: `k8s-hub` + `nativeauthenticator` + `oauthenticator`.
- **`deploy.sh`** — End-to-end deploy: ECR login → image build/push → IRSA → secrets → hub-templates ConfigMap → Karpenter NodePool → Postgres → LiteLLM → helm upgrade --install.
- **`launcher_ext/launcher_ext.py`** — Custom Jupyter server extension serving `/launcher` (the "Virtual AI 센터" landing page baked into each singleuser pod).
- **`entrypoint-dind.sh`** / **`dind-supervisor.conf`** — Docker-in-Docker startup via `start-notebook.d` hook.

## Notes

- Python version is fixed to **3.12** (via `jupyter/base-notebook:python-3.12` base image).
- Singleuser pods are built for **linux/amd64 only** — EKS nodes are t3.medium (amd64).
- VSIX extensions in `vsix_extensions/` are baked into the singleuser image at build time.
- Singleuser pods run in **privileged mode** for DinD — EKS nodes allow this by default.
- Claude Code OAuth: `openURL()` in `extension.js` is patched at build time to rewrite `redirect_uri` to `MANUAL_REDIRECT_URL` (`https://platform.claude.com/oauth/code/callback`), allowing auth to complete automatically via `claudeOAuthWaitForCompletion()`.
- **Claude Code → Bedrock**: Singleuser pods have `ANTHROPIC_BASE_URL=http://litellm:4000` and a per-user `ANTHROPIC_API_KEY` (LiteLLM virtual key) injected by `pre_spawn_hook`. LiteLLM uses IRSA to call Bedrock — no static AWS credentials.
- **Auth**: `COGNITO_DOMAIN` / `COGNITO_CLIENT_ID` / `COGNITO_CLIENT_SECRET` in `.env` configure the **Cognito User Pool** OIDC login. When empty, hub falls back to NativeAuthenticator (username/password) — kept as a safety net only.
- **postStart hook (singleuser)**: writes code-server settings.json, ensures `/usr/local/bin/claude` symlink (via sudo), pre-approves the env-var API key in `~/.claude.json`'s `customApiKeyResponses.approved` (last-20-char suffix). Wrapped with `|| true` + final `exit 0` so kubelet never sees a failed hook.
- **start-notebook.d/claude-symlink.sh**: belt-and-suspenders — re-creates the symlink at container start. Wrapped in `( ... ) || true` because jupyter's start.sh *sources* (not execs) these scripts; bare `exit` would kill the container before jupyter starts.
- **HTTPS / External access**: TLS termination at CloudFront with a publicly-trusted Amazon Trust Services cert on a `*.cloudfront.net` hostname (no custom domain needed). chp proxy serves plain HTTP; CloudFront → NLB :80 → proxy. Setup once: create a CloudFront distribution with origin = NLB hostname (`http-only`, port 80), `CachingDisabled` + `AllViewer` origin policy (for WebSocket + correct Host header forwarding). Set `JUPYTERHUB_PUBLIC_URL=https://<distribution>.cloudfront.net` in `.env` and add the same URL to the Cognito App Client's callback list (`{URL}/hub/oauth_callback`).
- **LiteLLM Admin UI**: `kubectl port-forward -n jupyterhub svc/litellm 4000:4000` → `http://localhost:4000/ui` (Username: `admin`, Password: `$LITELLM_MASTER_KEY`). External UI: dedicated CloudFront in front of `litellm-public` LoadBalancer Service, protected by the same WAF Web ACL.
- **Autoscaling**: Karpenter manages all worker nodes (NodePool: `default`, instance family t3/t3a/m5/m5a/m6i/m6a, sizes large–2xlarge, Spot + On-demand mix). User spawn → Pending pod → Karpenter provisions an EC2 in ~60s → pod schedules. Idle nodes consolidated after 30s. Cluster limit: 100 vCPU / 400Gi.

## Bootstrapping a new EKS cluster

For migrating to a new AWS account (e.g. `516008588502`):

```bash
# 0. 신규 계정 자격증명 등록 + profile 전환
#    (Access Key 방식이 가장 단순. SSO인 경우 `aws configure sso --profile newacct`)
aws configure --profile newacct      # Access Key ID / Secret / region(ap-northeast-2)
export AWS_PROFILE=newacct
aws sts get-caller-identity          # Account: 516008588502 확인
# .env에도 `AWS_PROFILE=newacct` 입력 → 이후 deploy.sh가 자동 사용

# 1. Create cluster with Karpenter pre-installed (eksctl bundles IAM/SQS/CFN setup)
eksctl create cluster -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: jupyterhub
  region: ap-northeast-2
  version: "1.34"
iam:
  withOIDC: true
karpenter:
  version: "1.0.5"
managedNodeGroups:
  - name: bootstrap        # tiny system nodegroup for hub/proxy/karpenter itself
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 1
    maxSize: 3
    privateNetworking: true
EOF

# 2. Tag private subnets + cluster SG for Karpenter discovery
# (eksctl --enable-karpenter does this; otherwise manual:
#   aws ec2 create-tags --resources <subnet-ids> --tags Key=karpenter.sh/discovery,Value=jupyterhub)

# 3. Request Bedrock Model Access (AWS Console → Bedrock → Model Access):
#    Claude Sonnet 4.6, Opus 4.6+, Haiku 4.5. 승인까지 수 분~수 일.

# 4. Create Cognito User Pool + App Client (콘솔):
#    - User Pool sign-in: Email
#    - App client: Confidential, OAuth flows = Authorization code, scopes = openid/profile/email
#    - Hosted UI domain prefix (예: jupyterhub-<account>)
#    - Callback URL은 deploy 후 CloudFront URL 받고 추가
#    - PreSignUp Lambda 등록: k8s/lambdas/pre_signup.py zip하여 jupyterhub-pre-signup 함수 생성

# 5. .env 채우기 (AWS_ACCOUNT_ID, EKS_CLUSTER_NAME, COGNITO_*)

# 6. ./deploy.sh 1회차 실행 → NLB 주소 받음

# 7. CloudFront 분배 2개 생성 (콘솔 또는 aws cloudfront create-distribution):
#    - origin1 = NLB proxy-public hostname, origin protocol = http-only
#    - origin2 = NLB litellm-public hostname (별도 분배)
#    - WAF IP allow-list 어태치

# 8. CloudFront URL을 JUPYTERHUB_PUBLIC_URL .env에 + Cognito App callback에 추가 → ./deploy.sh 재실행
```
