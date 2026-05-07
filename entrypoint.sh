#!/usr/bin/env bash
set -e

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Adjust UID
if [ "$HOST_UID" != "$(id -u dev)" ]; then
    usermod -u "$HOST_UID" dev
fi

# Adjust GID
if [ "$HOST_GID" != "$(id -g dev)" ]; then
    if getent group "$HOST_GID" >/dev/null 2>&1; then
        name=$(getent group "$HOST_GID" | cut -d: -f1)
        [ "$name" != "dev" ] && groupdel "$name" 2>/dev/null || true
    fi
    groupmod -g "$HOST_GID" dev
fi

chown -R dev:dev /home/dev 2>/dev/null || true

# Docker socket access — match host's docker group GID
if [ -S /var/run/docker.sock ]; then
    DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
    DOCKER_GROUP=$(getent group "$DOCKER_GID" | cut -d: -f1)
    if [ -z "$DOCKER_GROUP" ]; then
        groupadd -g "$DOCKER_GID" docker-host
        DOCKER_GROUP="docker-host"
    fi
    usermod -aG "$DOCKER_GROUP" dev
fi

# Generate Docker-specific Claude settings (yolo mode, no macOS hooks)
if [ -f /home/dev/.claude/settings.host.json ]; then
    mkdir -p /home/dev/.claude
    jq '{
      env: .env,
      permissions: {allow: ["*"]},
      theme: "dark",
      statusLine: .statusLine,
      enabledPlugins: .enabledPlugins
    }' /home/dev/.claude/settings.host.json > /home/dev/.claude/settings.json
    chown dev:dev /home/dev/.claude/settings.json
fi

# Start PostgreSQL
pg_ctlcluster 16 main start 2>/dev/null || true

exec runuser -u dev -- "$@"
