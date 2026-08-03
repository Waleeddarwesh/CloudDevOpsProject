# syntax=docker/dockerfile:1.7
# ==============================================================================
# Auth Service — Python 3.12 / Flask
# ------------------------------------------------------------------------------
# Multi-stage build:
#   Stage 1 (builder) compiles wheels for all dependencies. bcrypt and
#                     mysql-connector-python ship native extensions, so this
#                     stage needs gcc — which must NOT reach the final image.
#   Stage 2 (runtime) installs the pre-built wheels into a clean slim image.
#
# Keeping gcc/binutils out of the runtime image removes the single largest source
# of CVE findings in a Python container and cuts the image roughly in half.
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1 — build wheels
# ------------------------------------------------------------------------------
FROM python:3.12-slim AS builder

WORKDIR /build

# Build toolchain required to compile the native extensions in bcrypt.
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        build-essential \
        libffi-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

# Pre-compile every dependency into a wheel. The runtime stage then installs
# from these wheels with --no-index, so it never needs a compiler or network.
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

# ------------------------------------------------------------------------------
# Stage 2 — runtime
# ------------------------------------------------------------------------------
FROM python:3.12-slim AS runtime

LABEL org.opencontainers.image.title="ivolve-auth-service" \
      org.opencontainers.image.description="iVolve DevOps Roadmap — authentication API (Flask + MySQL)" \
      org.opencontainers.image.vendor="iVolve Technologies" \
      org.opencontainers.image.licenses="MIT"

# PYTHONDONTWRITEBYTECODE : no .pyc files, keeps the container filesystem read-only-friendly
# PYTHONUNBUFFERED        : stdout/stderr stream straight to the container log
#                           (without it, `kubectl logs` shows nothing until the buffer flushes)
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=5000

# curl is needed by the HEALTHCHECK below. tini reaps zombies and forwards
# SIGTERM so gunicorn shuts down gracefully instead of being SIGKILLed.
RUN apt-get update \
    && apt-get install --no-install-recommends -y curl tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /usr/sbin/nologin --uid 10001 appuser

WORKDIR /app

# Install from the locally built wheels only — --no-index guarantees the runtime
# image never reaches out to PyPI, making the build reproducible and air-gappable.
COPY --from=builder /wheels /wheels
COPY requirements.txt .
RUN pip install --no-cache-dir --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels

COPY --chown=appuser:appuser app.py .

USER appuser

EXPOSE 5000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD curl --fail --silent http://127.0.0.1:5000/health || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]

# Gunicorn instead of Flask's built-in server.
#
# `python app.py` starts Werkzeug's development server, which is single-threaded,
# not hardened against malformed requests, and prints a loud production warning.
# Gunicorn runs the same WSGI `app` object across 2 worker processes with 4
# threads each, so the service handles concurrent logins instead of serialising
# them behind one interpreter.
#
# The 30-attempt MySQL wait loop in app.py's `__main__` block is intentionally
# bypassed: startup ordering is handled by `depends_on: service_healthy` in
# Docker Compose and by an initContainer + readiness probe in Kubernetes, which
# are the correct layers for that concern.
CMD ["gunicorn", \
     "--bind", "0.0.0.0:5000", \
     "--workers", "2", \
     "--threads", "4", \
     "--timeout", "60", \
     "--graceful-timeout", "30", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app:app"]
