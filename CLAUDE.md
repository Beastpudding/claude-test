# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

JupyterHub on AWS EKS branded as "Virtual AI 센터". Provides multi-user Jupyter notebooks with integrated web-based VS Code (Code-Server 4.95.3), Docker-in-Docker, pre-installed VS Code extensions (Claude Code), and per-user Bedrock access via LiteLLM. Auth via AWS Cognito User Pool (NativeAuthenticator fallback).

## Build and Deploy Commands

```bash
# Full deployment: build images → push to ECR → IRSA → secrets → ConfigMaps
# (templates+branding) → Postgres → LiteLLM → Cognito branding → helm upgrade
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
- **`k8s/kb-logo.png`** — Brand logo. Used by both JupyterHub navbar (via `hub-branding` ConfigMap) and Cognito Managed Login (via base64 PNG asset upload).
- **`k8s/lambdas/pre_signup.py`** — Cognito Pre Sign-up Lambda trigger.
- **`Dockerfile.codeserver`** — Singleuser image: Code-Server, DinD, Claude Code VSIX + OAuth patch, native binary, Python 3.12.
- **`Dockerfile.jupyterhub`** — Hub image: `k8s-hub` + `nativeauthenticator` + `oauthenticator`.
- **`deploy.sh`** — End-to-end deploy: ECR login → image build/push → IRSA → secrets → ConfigMaps (branding/templates) → Postgres → LiteLLM → Cognito branding → helm upgrade --install.
- **`launcher_ext/launcher_ext.py`** — Custom Jupyter server extension serving `/launcher` (the "Virtual AI 센터" landing page baked into each singleuser pod).
- **`.env.example`** — Template: AWS config, EKS cluster name, admin user, proxy token, Cognito creds (`SSO_*` variable names — legacy), LiteLLM key.
- **`entrypoint-dind.sh`** / **`dind-supervisor.conf`** — Docker-in-Docker startup via `start-notebook.d` hook.

## Notes

- Python version is fixed to **3.12** (via `jupyter/base-notebook:python-3.12` base image).
- Singleuser pods are built for **linux/amd64 only** — EKS nodes are t3.medium (amd64).
- VSIX extensions in `vsix_extensions/` are baked into the singleuser image at build time.
- Singleuser pods run in **privileged mode** for DinD — EKS nodes allow this by default.
- Claude Code OAuth: `openURL()` in `extension.js` is patched at build time to rewrite `redirect_uri` to `MANUAL_REDIRECT_URL` (`https://platform.claude.com/oauth/code/callback`), allowing auth to complete automatically via `claudeOAuthWaitForCompletion()`.
- **Claude Code → Bedrock**: Singleuser pods have `ANTHROPIC_BASE_URL=http://litellm:4000` and a per-user `ANTHROPIC_API_KEY` (LiteLLM virtual key) injected by `pre_spawn_hook`. LiteLLM uses IRSA to call Bedrock — no static AWS credentials.
- **Auth**: `SSO_START_URL` / `SSO_CLIENT_ID` / `SSO_CLIENT_SECRET` in `.env` point at a **Cognito User Pool** (despite the `SSO_*` legacy naming). When empty, hub falls back to NativeAuthenticator (username/password) — kept as a safety net only.
- **postStart hook (singleuser)**: writes code-server settings.json, ensures `/usr/local/bin/claude` symlink (via sudo), pre-approves the env-var API key in `~/.claude.json`'s `customApiKeyResponses.approved` (last-20-char suffix). Wrapped with `|| true` + final `exit 0` so kubelet never sees a failed hook.
- **start-notebook.d/claude-symlink.sh**: belt-and-suspenders — re-creates the symlink at container start. Wrapped in `( ... ) || true` because jupyter's start.sh *sources* (not execs) these scripts; bare `exit` would kill the container before jupyter starts.
- **HTTPS**: `deploy.sh` creates a CA-signed TLS cert and enables `proxy.https.enabled=true` on the NLB. Install `jupyterhub-ca.crt` in the OS trust store once: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain jupyterhub-ca.crt`. For real external HTTPS swap the cert for ACM + Route53 alias to the NLB.
- **LiteLLM Admin UI**: `kubectl port-forward -n jupyterhub svc/litellm 4000:4000` → `http://localhost:4000/ui` (Username: `admin`, Password: `$LITELLM_MASTER_KEY`).
