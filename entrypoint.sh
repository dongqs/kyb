#!/usr/bin/env bash
set -e

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Adjust UID (remove conflicting user first, e.g. ubuntu from base image)
if [ "$HOST_UID" != "$(id -u dev)" ]; then
    if getent passwd "$HOST_UID" >/dev/null 2>&1; then
        name=$(getent passwd "$HOST_UID" | cut -d: -f1)
        [ "$name" != "dev" ] && userdel -r "$name" 2>/dev/null || true
    fi
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
if [ ! -f /home/dev/.claude/CLAUDE.md ]; then
    mascot="／人◕ ‿‿ ◕人＼"
    if [ -n "${KYB_PROJECT:-}" ]; then
        cat > /home/dev/.claude/CLAUDE.md << CLAUDE
# Container Environment

You are running inside a **kyb-managed Docker container** for project ${KYB_PROJECT}.

## Project
- **Name**: ${KYB_PROJECT}
- **Path**: /home/dev/projects/${KYB_PROJECT}

## Services
- **PostgreSQL 16** — running, trust auth, timezone Asia/Shanghai
  - DSN: \`postgresql://postgres:postgres@127.0.0.1:5432/postgres\`
- **ClickHouse** — running on host, no auth
  - Native: \`host.orb.internal:9000\`
  - CLI: \`clickhouse-client --host host.orb.internal\`
- **Docker** — available via mounted socket
- **glab** — pre-configured for git.leyantech.com

## Workflow
- Project code is in \`~/projects/${KYB_PROJECT}\`
- Use \`mig25\` for database migrations (DSN in \`.env\`)
- Commit and push changes — they persist on the host via volume mount
- End each conversation with: ${mascot}
CLAUDE
    else
        cat > /home/dev/.claude/CLAUDE.md << CLAUDE
# Container Environment

You are running inside a **kyb-managed disposable Docker container** — no project mounted.

## Services
- **PostgreSQL 16** — running, trust auth, timezone Asia/Shanghai
- **ClickHouse** — running on host, no auth (`host.orb.internal:9000`)
- **Docker** — available via mounted socket
- **glab** — pre-configured for git.leyantech.com
- End each conversation with: ${mascot}
CLAUDE
    fi
    # Append proxy info if configured
    if [ -n "${KYB_PROXY:-}" ]; then
        {
            echo ""
            echo "## Network Proxy"
            echo "- The container proxy is available at \`${KYB_PROXY}\`"
            if [ -n "${KYB_NO_PROXY:-}" ]; then
                echo "- Bypass proxy for: \`${KYB_NO_PROXY}\`"
            fi
            echo "- Configure it manually:"
            echo "  \`\`\`bash"
            echo "  export ALL_PROXY=${KYB_PROXY}"
            if [ -n "${KYB_NO_PROXY:-}" ]; then
                echo "  export NO_PROXY=${KYB_NO_PROXY}"
            fi
            echo "  \`\`\`"
        } >> /home/dev/.claude/CLAUDE.md
    fi

    # Append TTS Notify section
    {
        echo ""
        echo "## 主动通知（TTS Notify）"
        echo ""
        echo "长时间任务完成、巡检发现异常或需要外部操作确认时，主动通过 TTS 叫人。"
        echo ""
        echo "### 通知等级"
        echo "- \`done\` — 任务完成（一声提示音）"
        echo "- \`blocked\` — 巡检发现异常需人工干预（两声提示音，60秒后重试，最多3次）"
        echo "- \`urgent\` — 外部操作前确认（三声提示音，60秒后重试，最多3次）"
        echo ""
        echo "### 使用方式"
        echo '```bash'
        echo "# 任务完成时"
        echo "kyb notify done \"编译通过，测试全部绿\""
        echo ""
        echo "# 巡检异常需人工介入"
        echo "kyb notify blocked \"检测到服务器 502 错误，请检查\""
        echo ""
        echo "# 外部操作前确认"
        echo "kyb notify urgent \"准备推送生产环境，请确认\""
        echo '```'
        echo ""
        echo "### 规则"
        echo "- \`done\`: 超过 30 秒的任务完成后必通知"
        echo "- \`blocked\`: 巡检发现异常立即通知，60秒后未回应重试（最多3次）"
        echo "- \`urgent\`: 外部操作前立即通知，60秒后未回应重试（最多3次）"
    } >> /home/dev/.claude/CLAUDE.md

    chown dev:dev /home/dev/.claude/CLAUDE.md
fi

# Symlink host skills into Claude directory
if [ -d /home/dev/.claude-skills-host ] && [ ! -L /home/dev/.claude/skills ]; then
    ln -s /home/dev/.claude-skills-host /home/dev/.claude/skills
fi

# Start PostgreSQL
pg_ctlcluster 16 main start 2>/dev/null || true

# pip tools (may fail during image build, retry here at runtime)
runuser -u dev -- bash -l -c "pip install -i 'https://readonlyuser:mimashishiliuwei@nexus.leyantech.com/repository/pypi-all/simple' mig25 mig25-codegen 'requests[socks]' -U" 2>/dev/null || true

# Project setup: mise trust, npm install on first run
if [ -n "${KYB_PROJECT:-}" ] && [ -d "/home/dev/projects/${KYB_PROJECT}" ]; then
    runuser -u dev -- bash -l << EOF
        cd /home/dev/projects/${KYB_PROJECT}
        # Trust system mise config first so mise activate works cleanly
        /home/dev/.local/bin/mise trust /home/dev/.config/mise/config.toml || true
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

exec runuser -u dev -- "$@"
