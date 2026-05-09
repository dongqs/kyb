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

# Symlink host skills into Claude directory
if [ -d /home/dev/.claude-skills-host ] && [ ! -L /home/dev/.claude/skills ]; then
    ln -s /home/dev/.claude-skills-host /home/dev/.claude/skills
fi

# Append projects list to CLAUDE.md (from projects.txt)
if [ -f /home/dev/projects.txt ] && ! grep -q '## 项目列表' /home/dev/CLAUDE.md 2>/dev/null; then
    printf '\n## 项目列表\n\n' >> /home/dev/CLAUDE.md
    desc=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^#[[:space:]]*desc:[[:space:]]*(.*) ]]; then
            desc="${BASH_REMATCH[1]}"
        elif [[ -n "$line" && ! "$line" =~ ^# ]]; then
            repo_name=$(basename "$line" .git)
            if [ -n "$desc" ]; then
                echo "- **${repo_name}** — ${desc} (\`${line}\`)" >> /home/dev/CLAUDE.md
            else
                echo "- **${repo_name}** — \`${line}\`" >> /home/dev/CLAUDE.md
            fi
            desc=""
        fi
    done < /home/dev/projects.txt
    echo "" >> /home/dev/CLAUDE.md
fi

# Start PostgreSQL
pg_ctlcluster 16 main start 2>/dev/null || true

exec runuser -u dev -- "$@"
