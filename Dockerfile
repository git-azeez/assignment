# ==============================================================================
# File: Dockerfile
# Purpose: Hardened, zero-dependency container for bank build-info service
# ==============================================================================

# Base: Hardened minimal Python runtime on Alpine Linux
FROM python:3.12-alpine3.20

# Create dedicated non-root user and group (UID 10001) for least-privilege compliance
RUN addgroup -g 10001 appgroup && \
    adduser -u 10001 -G appgroup -s /bin/sh -D appuser && \
    mkdir -p /app && \
    chown -R appuser:appgroup /app

WORKDIR /app

# Copy application source code and the metadata baked by Cloud Build
COPY app.py /app/app.py
COPY build_info.json /app/build_info.json

# Enforce strict read-only permissions to prevent runtime tampering
RUN chown appuser:appgroup /app/app.py /app/build_info.json && \
    chmod 0555 /app/app.py && \
    chmod 0444 /app/build_info.json

EXPOSE 8080

# Switch permanently to unprivileged non-root user
USER 10001:10001

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080 \
    BUILD_INFO_PATH=/app/build_info.json

ENTRYPOINT ["python3", "/app/app.py"]