# syntax=docker/dockerfile:1.7
# ==============================================================================
# auth-service — Python 3.12 / Flask / Gunicorn
# ==============================================================================
# Two-stage build: compile native wheels in a builder, then copy them into a
# clean runtime image. This keeps the final image free of gcc, make, and header
# files that only exist to satisfy pip's build step.
# ==============================================================================

# --- Stage 1: build wheels for native extensions ---
FROM python:3.12-slim AS builder

WORKDIR /build

# Build tools are needed only for packages with C extensions (e.g., cffi).
# Installing them in a throwaway stage means the runtime image stays small.
RUN apt-get update \
    && apt-get install --no-install-recommends -y build-essential libffi-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

# --- Stage 2: production runtime ---
FROM python:3.12-slim AS runtime

LABEL org.opencontainers.image.title="ivolve-auth-service" \
      org.opencontainers.image.description="iVolve DevOps Roadmap — authentication API"

# PYTHONDONTWRITEBYTECODE — prevents .pyc files filling the read-only filesystem.
# PYTHONUNBUFFERED       — logs appear immediately instead of buffering.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# curl  — used by the HEALTHCHECK.
# tini  — PID 1 init that reaps zombies and forwards signals correctly.
RUN apt-get update \
    && apt-get install --no-install-recommends -y curl tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /usr/sbin/nologin --uid 10001 appuser

WORKDIR /app

# Install from the pre-built wheels — no compiler needed in this stage.
COPY --from=builder /wheels /wheels
COPY requirements.txt .
RUN pip install --no-cache-dir --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels

COPY --chown=appuser:appuser app.py .

# Drop to non-root. A compromised process cannot write to system paths or
# escalate via setuid binaries.
USER appuser
EXPOSE 5000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
    CMD curl --fail --silent http://127.0.0.1:5000/health || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "app.py"]
