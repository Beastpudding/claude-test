# ============================================================
# Harness Portal — static frontend only.
# Vite builds the React SPA (base=/services/harness-portal/), nginx serves it.
# No Python backend: App.jsx has built-in offline/mock fallbacks, so the portal
# works as a static guide + prompt gallery + demo dashboard behind JupyterHub.
# Build context = repo root (so corp-ca-bundle.pem is available):
#   docker build -f harness-portal/Dockerfile -t <ECR>/harness-portal:latest .
# ============================================================
FROM node:20-bookworm-slim AS build
WORKDIR /build
# Trust corporate TLS-inspection proxy CA at build time (gitignored; graceful skip).
COPY corp-ca-bundle.pe[m] /usr/local/share/ca-certificates/corp-bundle.crt
RUN if [ -s /usr/local/share/ca-certificates/corp-bundle.crt ]; then \
        update-ca-certificates || true; \
        npm config set cafile /usr/local/share/ca-certificates/corp-bundle.crt; \
    fi
COPY harness-portal/frontend/package*.json ./
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund
COPY harness-portal/frontend/ ./
RUN npm run build      # → /build/dist (base-path baked in)

FROM nginx:1.27-alpine
COPY harness-portal/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /build/dist /usr/share/nginx/html
EXPOSE 8000
