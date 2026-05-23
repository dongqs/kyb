# cc-connect Dockerfile
# Multi-stage build: download Go binary from GitHub Releases
# Usage:
#   docker build -t kyb-cc-connect:latest \
#     --build-arg CC_CONNECT_VERSION=v1.3.2 \
#     --build-arg TARGETARCH=arm64 \
#     -f docker/cc-connect/Dockerfile .
#
# Architecture: supports amd64 and arm64

# ---- Download Stage ----
FROM alpine:3.20 AS downloader

ARG CC_CONNECT_VERSION=v1.3.2
ARG TARGETARCH=amd64

RUN apk add --no-cache curl ca-certificates

# Download prebuilt binary from GitHub Releases
RUN curl -fsSL \
  "https://github.com/chenhg5/cc-connect/releases/download/${CC_CONNECT_VERSION}/cc-connect-linux-${TARGETARCH}.tar.gz" \
  -o /tmp/cc-connect.tar.gz && \
  tar xzf /tmp/cc-connect.tar.gz -C /usr/local/bin/ && \
  chmod +x /usr/local/bin/cc-connect && \
  cc-connect version

# ---- Runtime Stage ----
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata

# Copy binary from downloader
COPY --from=downloader /usr/local/bin/cc-connect /usr/local/bin/cc-connect

# Create config directory
RUN mkdir -p /root/.cc-connect

# Expose ports:
#   9111 - Webhook receiver
#   9810 - Bridge WebSocket (external adapters)
#   9820 - HTTP REST API (Web UI)
EXPOSE 9111 9810 9820

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD cc-connect version >/dev/null 2>&1 || exit 1

# Default command: run with Web UI for initial configuration
ENTRYPOINT ["cc-connect"]
CMD ["web"]
