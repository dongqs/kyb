#!/usr/bin/env bash
set -e

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

uid_changed=false; gid_changed=false

# Adjust UID (remove conflicting user first, e.g. ubuntu from base image)
if [ "$HOST_UID" != "$(id -u dev)" ]; then
    if getent passwd "$HOST_UID" >/dev/null 2>&1; then
        name=$(getent passwd "$HOST_UID" | cut -d: -f1)
        [ "$name" != "dev" ] && userdel -r "$name" 2>/dev/null || true
    fi
    usermod -u "$HOST_UID" dev
    uid_changed=true
fi

# Adjust GID
if [ "$HOST_GID" != "$(id -g dev)" ]; then
    if getent group "$HOST_GID" >/dev/null 2>&1; then
        name=$(getent group "$HOST_GID" | cut -d: -f1)
        [ "$name" != "dev" ] && groupdel "$name" 2>/dev/null || true
    fi
    groupmod -g "$HOST_GID" dev
    gid_changed=true
fi

# Only chown entire tree when UID/GID actually changed (common case: no change = skip)
if $uid_changed || $gid_changed; then
    chown -R dev:dev /home/dev 2>/dev/null || true
fi

# Always fix shared volume permissions — fresh volumes are root-owned regardless of UID/GID
chown -R dev:dev /home/dev/.gradle /home/dev/.m2/repository 2>/dev/null || true

# Clean stale Gradle locks from zombie daemons (common after failed builds)
rm -f /home/dev/.gradle/caches/journal-*/journal-*.lock

# Keep mise download archives so shared cache volumes avoid re-download
runuser -u dev -- bash -l -c "mise settings set always_keep_downloads true" 2>/dev/null || true

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
      skipDangerousModePermissionPrompt: true,
      hooks: .hooks,
      statusLine: .statusLine,
      enabledPlugins: .enabledPlugins
    } | with_entries(select(.value != null))' /home/dev/.claude-host-settings.json > /home/dev/.claude/settings.json

    if [ "${KYB_MODEL:-}" = "flash" ]; then
      jq '.env.ANTHROPIC_MODEL = "deepseek-v4-flash[1m]" |
          .env.ANTHROPIC_DEFAULT_OPUS_MODEL = "deepseek-v4-flash[1m]" |
          .env.ANTHROPIC_DEFAULT_SONNET_MODEL = "deepseek-v4-flash[1m]" |
          .env.ANTHROPIC_REASONING_MODEL = "deepseek-v4-flash[1m]"' \
          /home/dev/.claude/settings.json > /tmp/kyb-settings.json && \
        mv /tmp/kyb-settings.json /home/dev/.claude/settings.json
    fi

    chown -R dev:dev /home/dev/.claude
fi

# Skip Claude Code onboarding (theme picker, security notes, trust dialog)
if [ ! -f /home/dev/.claude.json ]; then
  project_trust='{}'
  if [ -n "${KYB_PROJECT:-}" ]; then
    project_trust=$(jq -n --arg p "/home/dev/projects/${KYB_PROJECT}" '{
      ($p): {
        allowedTools: [],
        mcpContextUris: [],
        mcpServers: {},
        enabledMcpjsonServers: [],
        disabledMcpjsonServers: [],
        hasTrustDialogAccepted: true,
        projectOnboardingSeenCount: 0,
        hasClaudeMdExternalIncludesApproved: false,
        hasClaudeMdExternalIncludesWarningShown: false
      }
    }')
  fi
  jq -n --argjson projects "$project_trust" '{
    hasCompletedOnboarding: true,
    migrationVersion: 13,
    projects: $projects
  }' > /home/dev/.claude.json
  chown dev:dev /home/dev/.claude.json
fi

# Rewrite HTTPS→SSH for GitLab (CI requires HTTPS in .gitmodules, ssh complains about this often)
git config --system url."git@git.leyantech.com:".insteadOf "https://git.leyantech.com/"

# Configure glab on first run
if [ -n "${GITLAB_TOKEN:-}" ] && [ ! -f /home/dev/.config/glab-cli/config.yml ]; then
    # Resolve GitLab username from token
    GL_USER=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "https://git.leyantech.com/api/v4/user" | jq -r '.username // empty')
    GL_USER="${GL_USER:-user}"

    mkdir -p /home/dev/.config/glab-cli
    cat > /home/dev/.config/glab-cli/config.yml << YAML
git_protocol: ssh
host: git.leyantech.com
hosts:
    git.leyantech.com:
        api_host: git.leyantech.com
        git_protocol: ssh
        api_protocol: https
        user: ${GL_USER}
        token: ${GITLAB_TOKEN}
YAML
    chown -R dev:dev /home/dev/.config/glab-cli
    chmod 600 /home/dev/.config/glab-cli/config.yml
fi

# Generate container CLAUDE.md
mkdir -p /home/dev/.claude
chown dev:dev /home/dev/.claude 2>/dev/null || true
if [ ! -f /home/dev/.claude/CLAUDE.md ]; then
    mascot="／人◕ ‿‿ ◕人＼"
    {
        echo "# ${mascot} kyb Sandbox"
        echo ""
        echo "You are an AI coding agent inside a **kyb-managed Docker container**."
        echo ""
        echo "## Project"

        if [ -n "${KYB_PROJECT:-}" ]; then
            echo "- **Name**: ${KYB_PROJECT}"
            echo "- **Aka**: 「可以不」「可以吧」「不可以？」— 根据上下文选一个"
            echo "- **Source**: \`~/projects/${KYB_PROJECT}\`"
            echo "- **DB migrations**: \`mig25\` (DSN in project \`.env\`)"
        else
            echo "- No project mounted."
        fi

        echo ""
        echo "## Workflow"
        echo "1. **Understand** — what does the human want?"
        echo "2. **Code** — edit, build, test in \`~/projects/${KYB_PROJECT:-<project>}\`"
        echo "3. **Commit & push** — changes persist on host via volume mount"
        echo "4. **Notify** — \`kyb notify done|blocked|urgent <msg>\` to alert the human"
        echo "   - \`done\`: task complete (long tasks must notify)"
        echo "   - \`blocked\`: need human intervention"
        echo "   - \`urgent\`: confirm before external actions"
        echo "5. **End** each conversation with: ${mascot}"

        echo ""
        echo "## Services"
        echo "- **PostgreSQL 16**: \`postgresql://postgres:postgres@127.0.0.1:5432/postgres\` (trust auth)"
        echo "- **ClickHouse**: \`clickhouse-client --host host.orb.internal\`"
        echo "- **Docker**: via mounted \`/var/run/docker.sock\`"
        echo "- **glab**: GitLab CLI, pre-configured for git.leyantech.com"
        echo "- **mise**: manages Node/Ruby/Java versions"

        if [ -n "${KYB_PROXY:-}" ]; then
            echo "- **Proxy**: ${KYB_PROXY}"
            if [ -n "${KYB_NO_PROXY:-}" ]; then
                echo "  (bypass: ${KYB_NO_PROXY})"
            fi
        fi

        echo ""
        echo "## kyb Docs"
        echo "- Read \`/home/dev/kyb\` for container setup, config reference, and how-tos."
        echo ""
        echo "---"
        echo "<sub>Auto-generated by entrypoint.sh — do not edit manually.</sub>"
    } > /home/dev/.claude/CLAUDE.md

    chown dev:dev /home/dev/.claude/CLAUDE.md
fi

# Symlink host skills into Claude directory
if [ -d /home/dev/.claude-skills-host ] && [ ! -L /home/dev/.claude/skills ]; then
    ln -s /home/dev/.claude-skills-host /home/dev/.claude/skills
fi

# pip tools (may fail during image build, retry here at runtime)
runuser -u dev -- bash -l -c "pip install -i 'https://readonlyuser:mimashishiliuwei@nexus.leyantech.com/repository/pypi-all/simple' mig25 mig25-codegen 'requests[socks]'" 2>/dev/null || true

# Project setup: mise trust, npm install on first run
if [ -n "${KYB_PROJECT:-}" ] && [ -d "/home/dev/projects/${KYB_PROJECT}" ]; then
    runuser -u dev -- bash -l << EOF
        cd /home/dev/projects/${KYB_PROJECT}
        # Trust system mise config first so mise activate works cleanly
        /home/dev/.local/bin/mise trust /home/dev/.config/mise/config.toml || true
        # Enable experimental plugins (swift, etc.)
        /home/dev/.local/bin/mise settings experimental=true 2>/dev/null || true
        eval "\$(/home/dev/.local/bin/mise activate bash)"
        # Trust project-level mise config if any
        if [ -f mise.toml ]; then
            mise trust mise.toml || true
        fi

        # Node dependencies
        if [ -f package.json ] && { [ ! -d node_modules ] || [ -z "\$(ls -A node_modules 2>/dev/null)" ]; }; then
            if [ -f yarn.lock ]; then
                yarn install --frozen-lockfile || true
            else
                npm install || true
            fi
        fi

        # Ruby dependencies
        if [ -f Gemfile ]; then
            bundle install || true
        fi
EOF
fi

touch /tmp/kyb-ready

exec runuser -u dev -- "$@"
