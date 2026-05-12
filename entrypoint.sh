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

# Generate Docker-specific Claude settings on first run only
if [ ! -f /home/dev/.claude/settings.json ] && [ -f /home/dev/.claude-host-settings.json ]; then
    mkdir -p /home/dev/.claude
    jq '{
      env: .env,
      permissions: {allow: ["*"]},
      theme: "dark",
      hooks: .hooks,
      statusLine: .statusLine,
      enabledPlugins: .enabledPlugins
    }' /home/dev/.claude-host-settings.json > /home/dev/.claude/settings.json
    chown -R dev:dev /home/dev/.claude
fi

# Configure glab on first run
if [ -n "${GITLAB_TOKEN:-}" ] && [ ! -f /home/dev/.config/glab-cli/config.yml ]; then
    mkdir -p /home/dev/.config/glab-cli
    cat > /home/dev/.config/glab-cli/config.yml << YAML
git_protocol: ssh
host: git.leyantech.com
hosts:
    git.leyantech.com:
        api_host: git.leyantech.com
        git_protocol: ssh
        api_protocol: https
        user: dongqs
        token: ${GITLAB_TOKEN}
YAML
    chown -R dev:dev /home/dev/.config/glab-cli
    chmod 600 /home/dev/.config/glab-cli/config.yml
fi

# Generate sandbox CLAUDE.md
if [ ! -f /home/dev/.claude/CLAUDE.md ]; then
    if [ -n "${SANDBOX_PROJECT:-}" ]; then
        cat > /home/dev/.claude/CLAUDE.md << CLAUDE
# Sandbox Environment

You are running inside a **kyb dev sandbox** container.

## Project
- **Name**: ${SANDBOX_PROJECT}
- **Path**: /home/dev/projects/${SANDBOX_PROJECT}

## Services
- **PostgreSQL 16** — running, trust auth, timezone Asia/Shanghai
  - DSN: \`postgresql://postgres:postgres@127.0.0.1:5432/postgres\`
- **Docker** — available via mounted socket
- **glab** — pre-configured for git.leyantech.com

## Workflow
- Project code is in \`~/projects/${SANDBOX_PROJECT}\`
- Use \`mig25\` for database migrations (DSN in \`.env\`)
- Commit and push changes — they persist on the host via volume mount
CLAUDE
    else
        cat > /home/dev/.claude/CLAUDE.md << CLAUDE
# Sandbox Environment

You are running inside a **kyb play sandbox** — a disposable container with no project mounted.

## Services
- **PostgreSQL 16** — running, trust auth, timezone Asia/Shanghai
- **Docker** — available via mounted socket
- **glab** — pre-configured for git.leyantech.com
CLAUDE
    fi
    chown dev:dev /home/dev/.claude/CLAUDE.md
fi

# Symlink host skills into Claude directory
if [ -d /home/dev/.claude-skills-host ] && [ ! -L /home/dev/.claude/skills ]; then
    ln -s /home/dev/.claude-skills-host /home/dev/.claude/skills
fi

# Start PostgreSQL
pg_ctlcluster 16 main start 2>/dev/null || true

# Project setup: mise trust, npm install on first run
if [ -n "${SANDBOX_PROJECT:-}" ] && [ -d "/home/dev/projects/${SANDBOX_PROJECT}" ]; then
    runuser -u dev -- bash -l << EOF
        cd /home/dev/projects/${SANDBOX_PROJECT}
        ~/.local/bin/mise trust 2>/dev/null || true
        eval "\$(~/.local/bin/mise activate bash)"
        if [ -f package.json ] && [ ! -d node_modules -o -z "\$(ls -A node_modules 2>/dev/null)" ]; then
            npm install || true
        fi
EOF
fi

exec runuser -u dev -- "$@"
