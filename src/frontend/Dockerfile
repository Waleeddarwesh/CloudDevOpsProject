# syntax=docker/dockerfile:1.7
# ==============================================================================
# Frontend Service — Node.js 22 / Express 5 / EJS
# ------------------------------------------------------------------------------
# Multi-stage build:
#   Stage 1 (deps)    installs production dependencies only, in a throwaway layer.
#   Stage 2 (runtime) copies the resolved node_modules + source into a clean image.
#
# The build stage keeps npm's cache, build toolchain and dev metadata out of the
# final image, which both shrinks the image and removes packages that Trivy would
# otherwise flag as vulnerable but which are never executed at runtime.
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1 — dependency resolution
# ------------------------------------------------------------------------------
FROM node:22-alpine AS deps

WORKDIR /app

# Copy only the manifests first. Docker caches this layer, so dependencies are
# re-installed only when package.json actually changes — not on every code edit.
COPY package*.json ./

# --omit=dev  : skip devDependencies (nothing in this service needs them at runtime)
# --no-audit  : the security audit runs in the Jenkins pipeline via Trivy instead
# --no-fund   : suppress funding output so build logs stay readable in CI
RUN npm install --omit=dev --no-audit --no-fund

# ------------------------------------------------------------------------------
# Stage 2 — runtime
# ------------------------------------------------------------------------------
FROM node:22-alpine AS runtime

# Container metadata (OCI standard labels) — surfaces in `docker inspect`,
# in ECR, and in vulnerability-scanner reports.
LABEL org.opencontainers.image.title="ivolve-frontend" \
      org.opencontainers.image.description="iVolve DevOps Roadmap — web frontend (Express + EJS)" \
      org.opencontainers.image.vendor="iVolve Technologies" \
      org.opencontainers.image.licenses="MIT"

# tini is a minimal init process. Node is PID 1 without it, which means it never
# reaps zombie children and ignores SIGTERM by default — so `docker stop` and
# Kubernetes pod termination would hang until the 30s grace period expires.
RUN apk add --no-cache tini=~0.19

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

# `node` is a non-root user (uid 1000) that ships with the official image.
# Copying with --chown avoids a second layer just to fix file ownership.
COPY --chown=node:node --from=deps /app/node_modules ./node_modules
COPY --chown=node:node package*.json ./
COPY --chown=node:node server.js ./
COPY --chown=node:node views ./views
COPY --chown=node:node public ./public

# Drop root. Everything from here runs unprivileged, which satisfies the
# `runAsNonRoot: true` policy enforced by the Kubernetes securityContext.
USER node

EXPOSE 3000

# Liveness signal for Docker Compose. Kubernetes ignores this and uses its own
# httpGet probes (see 04-Kubernetes/manifests/), but it makes `docker compose up`
# dependency ordering work correctly for local development.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD node -e "require('http').get('http://127.0.0.1:3000/',r=>process.exit(r.statusCode<500?0:1)).on('error',()=>process.exit(1))"

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
