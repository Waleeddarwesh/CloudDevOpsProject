# syntax=docker/dockerfile:1.7
# ==============================================================================
# frontend — Node.js 22 / Express 5 / EJS
# ==============================================================================
# Two-stage build: install production dependencies in a deps stage, then copy
# only node_modules into the runtime stage. This avoids shipping npm caches,
# build logs, and devDependencies in the final image.
# ==============================================================================

# --- Stage 1: install production dependencies ---
FROM node:26-alpine AS deps

WORKDIR /app
COPY package*.json ./

# Upgrade npm to fix CVE-2026-59873 in bundled node-tar
RUN npm install -g npm@latest \
    && npm install --omit=dev --no-audit --no-fund

# --- Stage 2: production runtime ---
FROM node:26-alpine AS runtime

LABEL org.opencontainers.image.title="ivolve-frontend" \
      org.opencontainers.image.description="iVolve DevOps Roadmap — web frontend"

# tini — PID 1 init that reaps zombies and forwards signals correctly.
# Without it, Node.js ignores SIGTERM and the container takes 10 seconds to
# stop (the Docker kill timeout) instead of shutting down gracefully.
RUN apk add --no-cache tini

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

# Copy node_modules from the deps stage, owned by the 'node' user.
COPY --chown=node:node --from=deps /app/node_modules ./node_modules
COPY --chown=node:node package*.json ./
COPY --chown=node:node server.js ./
COPY --chown=node:node views ./views
COPY --chown=node:node public ./public

# Drop to non-root. The built-in 'node' user exists in the base image.
USER node
EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD node -e "require('http').get('http://127.0.0.1:3000/',r=>process.exit(r.statusCode<500?0:1)).on('error',()=>process.exit(1))"

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
