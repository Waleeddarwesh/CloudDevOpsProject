# syntax=docker/dockerfile:1.7
# ==============================================================================
# roadmap-service — Java 21 / Spring Boot
# ==============================================================================
# Two-stage build: Maven compiles the fat JAR in a builder image that ships the
# full JDK and Maven cache, then the runtime stage copies only the JAR into a
# minimal JRE image. Final image is ~200 MB instead of ~800 MB.
# ==============================================================================

# --- Stage 1: Maven build ---
FROM maven:3.9.11-eclipse-temurin-21 AS build

WORKDIR /build

# Copy pom.xml first and resolve dependencies in a separate layer.
# Source changes won't re-download the entire Maven repository.
COPY pom.xml .
RUN mvn -B dependency:go-offline

COPY src ./src
RUN mvn -B clean package -DskipTests

# --- Stage 2: production runtime ---
FROM eclipse-temurin:25-jre-alpine AS runtime

LABEL org.opencontainers.image.title="ivolve-roadmap-service" \
      org.opencontainers.image.description="iVolve DevOps Roadmap — roadmap API"

# curl  — used by the HEALTHCHECK and Kubernetes probes.
# tini  — PID 1 init that reaps zombies and forwards signals correctly.
RUN apk add --no-cache curl tini \
    && addgroup --system --gid 10001 appgroup \
    && adduser  --system --uid 10001 --ingroup appgroup --shell /sbin/nologin appuser

WORKDIR /app
COPY --from=build --chown=appuser:appgroup /build/target/roadmap-service-1.0.0.jar app.jar

# Drop to non-root.
USER appuser
EXPOSE 8080

# MaxRAMPercentage — lets the JVM size itself to the container's cgroup limit
#                    instead of reading the host's total RAM.
# UseSerialGC     — single-threaded GC, ideal for a container with ≤1 CPU.
# ExitOnOutOfMemoryError — crash immediately so the orchestrator can restart,
#                          rather than limping along in a degraded state.
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseSerialGC -XX:+ExitOnOutOfMemoryError"

HEALTHCHECK --interval=15s --timeout=5s --start-period=45s --retries=5 \
    CMD curl --fail --silent http://127.0.0.1:8080/api/roadmap || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
