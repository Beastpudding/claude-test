# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

JupyterHub + Code-Server Docker deployment system for local and air-gapped (offline) environments. Provides multi-user Jupyter notebooks with integrated web-based VS Code (Code-Server 4.95.3), Docker-in-Docker support, and pre-installed VS Code extensions.

## Build and Deploy Commands

```bash
# Full deployment (standard)
./deploy.sh

# Air-gapped/offline deployment
./deploy.sh --airgap

# Build user container image manually
docker build -f Dockerfile.codeserver -t codeserver-kbdev:local \
  --build-arg CODE_VERSION=4.95.3 --build-arg TARGETARCH=amd64 .

# Build and start all services
docker compose up -d --build

# View logs
docker compose logs -f hub

# Shutdown
docker compose down
```

There is no test suite or linter — this is an infrastructure/deployment project.

## Architecture

**Two-container system orchestrated by Docker Compose:**

1. **Hub container** (`Dockerfile.jupyterhub`) — Runs JupyterHub 4.0.2 with DockerSpawner. Connects to the host Docker socket to spawn per-user containers on demand. Uses NativeAuthenticator for local signup/login.

2. **User containers** (`Dockerfile.codeserver`) — Spawned per-user from `codeserver-kbdev:local` image. Based on `jupyter/base-notebook`, adds Code-Server, Docker-in-Docker (dockerd via supervisord), and pre-installed VSIX extensions. Runs in privileged mode for DinD.

**Key data flow:** Hub listens on port 8000 (proxy) and 8081 (internal API). When a user logs in, DockerSpawner creates a user container on `jupyterhub-network`. User data persists in `jupyterhub-user-{username}` Docker volumes.

## Key Configuration Files

- **`jupyterhub_config.py`** — Spawner settings (DemoFormSpawner for image selection), auth config, network/volume mounts, privileged mode, spawn timeout (120s). Hub connects at `http://jupyterhub:8081`.
- **`docker-compose.yml`** — Service definitions, volume mounts (`jupyterhub-data`, `vsix_files`), network config, environment variables.
- **`.env.example`** — Template for required env vars: `JUPYTERHUB_ADMIN`, `JUPYTERHUB_PORT`, `DOCKER_NOTEBOOK_IMAGE`, PyPI mirror settings for air-gapped mode.
- **`entrypoint-dind.sh`** / **`dind-supervisor.conf`** — Docker-in-Docker startup: supervisord manages dockerd with overlay2 storage driver.

## Notes

- VSIX extensions in `vsix_extensions/` are pre-downloaded for offline installation (OpenCode, Live Server).
- User containers get sudo access (default password: `jovyan`).
- Code comments are in Korean.
