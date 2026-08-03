# syntax=docker/dockerfile:1.7
# ==============================================================================
# Roadmap Service — Java 21 / Spring Boot 3.5.4
# ------------------------------------------------------------------------------
# Multi-stage build:
#   Stage 1 (build)   runs Maven with the full JDK to produce the fat JAR.
#   Stage 2 (runtime) ships only a JRE + the JAR.
#
# The Maven image is ~800 MB and contains a compiler, the entire dependency
# cache and the JDK's development tooling. None of it is needed to *run* the
# service, and all of it would be scanned as attack surface.
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1 — compile and package
# ------------------------------------------------------------------------------
FROM maven:3.9.11-eclipse-temurin-21 AS build

WORKDIR /build

# Resolve dependencies in their own cached layer. `go-offline` downloads the
# full dependency tree, so a change to a .java file re-runs only the compile
# step instead of re-downloading Spring Boot on every build.
COPY pom.xml .
RUN mvn -B dependency:go-offline

COPY src ./src

# -B  : batch mode, no ANSI progress spam in Jenkins console output
# Tests are skipped here because the Jenkins pipeline runs them in a dedicated
# `Unit Tests` stage where the surefire reports can be published and archived.
RUN mvn -B clean package -DskipTests

# ------------------------------------------------------------------------------
# Stage 2 — runtime
# ------------------------------------------------------------------------------
FROM eclipse-temurin:21-jre-alpine AS runtime

LABEL org.opencontainers.image.title="ivolve-roadmap-service" \
      org.opencontainers.image.description="iVolve DevOps Roadmap — roadmap API (Spring Boot)" \
      org.opencontainers.image.vendor="iVolve Technologies" \
      org.opencontainers.image.licenses="MIT"

# curl for the HEALTHCHECK; tini so the JVM receives SIGTERM and Spring Boot can
# run its shutdown hooks rather than being killed mid-request.
RUN apk add --no-cache curl tini \
    && addgroup --system --gid 10001 appgroup \
    && adduser  --system --uid 10001 --ingroup appgroup --shell /sbin/nologin appuser

WORKDIR /app

COPY --from=build --chown=appuser:appgroup /build/target/roadmap-service-1.0.0.jar app.jar

USER appuser

EXPOSE 8080

# JVM flags tuned for running inside a container with a memory limit:
#   MaxRAMPercentage=75  the JVM sizes its heap from the *cgroup* limit rather
#                        than the host's total RAM. Without this the JVM sees the
#                        node's memory, sets a huge heap, and the kernel OOM-kills
#                        the pod the moment it grows — the classic "Java in K8s"
#                        failure. 75% leaves headroom for metaspace and threads.
#   UseSerialGC          lowest memory + startup overhead for a small,
#                        low-concurrency service; G1's region tables are wasted here.
#   +ExitOnOutOfMemoryError  fail fast so Kubernetes restarts the pod instead of
#                        leaving a wedged JVM thrashing the collector forever.
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseSerialGC -XX:+ExitOnOutOfMemoryError -Djava.security.egd=file:/dev/./urandom"

HEALTHCHECK --interval=15s --timeout=5s --start-period=45s --retries=5 \
    CMD curl --fail --silent http://127.0.0.1:8080/api/roadmap || exit 1

ENTRYPOINT ["/sbin/tini", "--"]

# `sh -c` is required so $JAVA_OPTS is expanded by the shell. tini stays PID 1
# and forwards signals, so the extra shell process does not break termination.
CMD ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
