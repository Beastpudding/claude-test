# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

JupyterHub deployment on AWS EKS. Provides multi-user Jupyter notebooks with integrated web-based VS Code (Code-Server 4.95.3), Docker-in-Docker support, and pre-installed VS Code extensions (including Claude Code).

## Build and Deploy Commands

```bash
# Full deployment: build images → push to ECR → helm upgrade --install
./deploy.sh

# Build singleuser image only
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

1. **Hub pod** (`Dockerfile.jupyterhub`) — Runs JupyterHub with KubeSpawner. Built from `quay.io/jupyterhub/k8s-hub` with NativeAuthenticator added. Spawns per-user pods on demand.

2. **Singleuser pods** (`Dockerfile.codeserver`) — Spawned per user from `codeserver-kbdev` image. Based on `jupyter/base-notebook:python-3.12`. Includes Code-Server, Docker-in-Docker (dockerd via supervisord), Claude Code VSIX with OAuth patch, and the custom launcher page.

3. **Proxy pod** — Managed by Helm chart (configurable-http-proxy). Exposed via AWS NLB LoadBalancer service.

**Key data flow:** Hub listens on port 8000 (proxy) and 8081 (internal API). When a user logs in, KubeSpawner creates a singleuser Pod in the `jupyterhub` namespace. User data persists in EBS-backed PVCs (`gp2` StorageClass).

## Key Configuration Files

- **`helm/values.yaml`** — All JupyterHub Helm chart settings: spawner, auth, storage, images, ingress, resource limits.
- **`Dockerfile.codeserver`** — Singleuser image: Code-Server, DinD, Claude Code VSIX + OAuth patch, Python 3.12.
- **`Dockerfile.jupyterhub`** — Hub image: `k8s-hub` + NativeAuthenticator.
- **`deploy.sh`** — End-to-end deploy: ECR login → image build/push → helm upgrade --install.
- **`.env.example`** — Template: AWS config, EKS cluster name, admin user, proxy token.
- **`entrypoint-dind.sh`** / **`dind-supervisor.conf`** — Docker-in-Docker startup via `start-notebook.d` hook.

## Notes

- Python version is fixed to **3.12** (via `jupyter/base-notebook:python-3.12` base image).
- VSIX extensions in `vsix_extensions/` are baked into the singleuser image at build time.
- Singleuser pods run in **privileged mode** for DinD — EKS nodes allow this by default.
- Claude Code OAuth: `openURL()` in `extension.js` is patched at build time to rewrite `redirect_uri` to `MANUAL_REDIRECT_URL` (`https://platform.claude.com/oauth/code/callback`), allowing auth to complete automatically via `claudeOAuthWaitForCompletion()`.
- For HTTPS / custom domain: set `ingress.enabled: true` in `helm/values.yaml` and install AWS Load Balancer Controller on the cluster.
