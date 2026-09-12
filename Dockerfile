# Base: Hardened minimal Python runtime
FROM python:3.12-alpine3.20

# Create dedicated non-root user (UID 10001) for strict least-privilege
RUN addgroup -g 10001 appgroup && \
    adduser -u 10001 -G appgroup -s /bin/sh -D appuser && \
    mkdir -p /app && \
    chown -R appuser:appgroup /app

WORKDIR /app

# Accept build arguments passed by Google Cloud Build substitutions
ARG VERSION="v1.0.0"
ARG COMMIT_SHA="unknown"
ARG BUILD_TIME="unknown"
ARG APP_ENV="production"

# Permanently stamp immutable build metadata into container filesystem at build time
RUN echo "{\"application\":\"build-info-api\",\"version\":\"${VERSION}\",\"git_commit\":\"${COMMIT_SHA}\",\"build_time\":\"${BUILD_TIME}\",\"environment\":\"${APP_ENV}\"}" > /app/build_info.json

# Copy code and restrict permissions to read-only
COPY app.py /app/app.py
RUN chmod 0555 /app/app.py && \
    chmod 0444 /app/build_info.json

EXPOSE 8080

# Run container as unprivileged non-root user
USER 10001:10001

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

ENTRYPOINT ["python3", "/app/app.py"]
