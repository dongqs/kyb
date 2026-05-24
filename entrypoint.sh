#!/usr/bin/env bash
set -e

# Safety: prevent infra-boss from accidentally deleting its own container
docker() {
  for arg in "$@"; do
    if echo "$arg" | grep -q "kyb-infra-boss$"; then
      echo "ERROR: refusing to delete kyb-infra-boss from inside itself" >&2
      echo "       Run this from another container or the host:" >&2
      echo "       docker rm -f kyb-infra-boss" >&2
      return 1
    fi
  done
  command docker "$@"
}

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Export proxy env vars from KYB_PROXY if not already set
# Dockerfile clears proxy env vars in the final image.
# Go tools (glab etc.) need HTTPS_PROXY for SOCKS5; Ruby/Python use ALL_PROXY.
if [ -n "${KYB_PROXY:-}" ]; then
  [ -z "${ALL_PROXY:-}" ]    && export ALL_PROXY="${KYB_PROXY}"   && export all_proxy="${KYB_PROXY}"
  [ -z "${HTTPS_PROXY:-}" ]  && export HTTPS_PROXY="${KYB_PROXY}" && export https_proxy="${KYB_PROXY}"
  [ -z "${HTTP_PROXY:-}" ]   && export HTTP_PROXY="${KYB_PROXY}"  && export http_proxy="${KYB_PROXY}"
fi

uid_changed=false; gid_changed=false

# Adjust UID (remove conflicting user first, e.g. ubuntu from base image)
if [ "$HOST_UID" != "$(id -u dev)" ]; then
    if getent passwd "$HOST_UID" >/dev/null 2>&1; then
        name=$(getent passwd "$HOST_UID" | cut -d: -f1)
        uid=$(getent passwd "$HOST_UID" | cut -d: -f3)
        [ "$name" != "dev" ] && [ "$uid" -ge 1000 ] && userdel -r "$name" 2>/dev/null || true
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
    # Skip known host bind mounts (projects/, .ssh-host, etc.) to avoid
    # propagating incorrect ownership to the host filesystem
    for dir in /home/dev/projects /home/dev/.ssh-host /home/dev/sing-box-config /home/dev/.claude-skills-host /home/dev/.claude-host-settings.json /home/dev/.config/kyb; do
        [ -e "$dir" ] && chown dev:dev "$dir" 2>/dev/null || true
    done
    chown -R dev:dev /home/dev 2>/dev/null || true
fi

# Only fix shared volume permissions on first use (fresh volumes are root-owned)
find /home/dev/.gradle /home/dev/.m2/repository /home/dev/.local/share/mise/downloads -maxdepth 0 -user root -print -quit |
  grep -q . &&
  chown -R dev:dev /home/dev/.gradle /home/dev/.m2/repository /home/dev/.local/share/mise/downloads 2>/dev/null || true

# Copy .ssh from read-only host mount to writable directory (Issue #22)
if [ -d /home/dev/.ssh-host ] && [ ! -d /home/dev/.ssh ]; then
    cp -r /home/dev/.ssh-host /home/dev/.ssh
    chown -R dev:dev /home/dev/.ssh
    chmod 600 /home/dev/.ssh/id_rsa /home/dev/.ssh/id_ed25519 2>/dev/null || true
fi

# Clean stale Gradle locks from zombie daemons (common after failed builds)
rm -f /home/dev/.gradle/caches/journal-*/journal-*.lock

# Add service aliases to /etc/hosts so projects can connect by hostname
grep -q "postgres" /etc/hosts 2>/dev/null ||
  printf "127.0.0.1\tpostgres clickhouse kafka redis\n" >> /etc/hosts

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

# Rewrite HTTPS->SSH for GitLab (CI requires HTTPS in .gitmodules, ssh complains about this often)
git config --system url."git@git.leyantech.com:".insteadOf "https://git.leyantech.com/"

# Configure glab on first run
if [ -n "${GITLAB_TOKEN:-}" ] && [ ! -f /home/dev/.config/glab-cli/config.yml ]; then
    # Resolve GitLab username from token (network may fail → fallback to "user")
    GL_USER=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "https://git.leyantech.com/api/v4/user" | jq -r '.username // empty') || true
    GL_USER="${GL_USER:-user}"

    mkdir -p /home/dev/.config/glab-cli
    # Safe heredoc: quoted delimiter prevents shell injection from env var values.
    cat > /home/dev/.config/glab-cli/config.yml << 'YAML'
git_protocol: ssh
host: git.leyantech.com
hosts:
    git.leyantech.com:
        api_host: git.leyantech.com
        git_protocol: ssh
        api_protocol: https
        user: GL_USER_PLACEHOLDER
        token: GITLAB_TOKEN_PLACEHOLDER
YAML
    sed -i "s|GL_USER_PLACEHOLDER|${GL_USER}|g; s|GITLAB_TOKEN_PLACEHOLDER|${GITLAB_TOKEN}|g" \
      /home/dev/.config/glab-cli/config.yml
    chown -R dev:dev /home/dev/.config/glab-cli
    chmod 600 /home/dev/.config/glab-cli/config.yml
fi

# Configure gh on first run (Issue #14)
if [ -n "${GITHUB_TOKEN:-}" ] && [ ! -f /home/dev/.config/gh/hosts.yml ]; then
    mkdir -p /home/dev/.config/gh
    echo "$GITHUB_TOKEN" | runuser -u dev -- bash -l -c 'gh auth login --with-token' 2>/dev/null || true
    chown -R dev:dev /home/dev/.config/gh 2>/dev/null || true
fi

# Go proxy for China (proxy.golang.org is blocked by GFW)
if [ -z "${GOPROXY:-}" ]; then
  cat > /etc/profile.d/go.sh << 'GOEOF'
export GOPROXY=https://goproxy.cn,direct
GOEOF
  chmod 644 /etc/profile.d/go.sh

  # Also set in dev/.bashrc for non-login shells
  if ! grep -q 'GOPROXY' /home/dev/.bashrc 2>/dev/null; then
    cat >> /home/dev/.bashrc << 'GOEOF'

# Go proxy for China (proxy.golang.org is blocked by GFW)
if [ -z "${GOPROXY:-}" ]; then
  export GOPROXY=https://goproxy.cn,direct
fi
GOEOF
  fi
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
        echo "   - \`done\`: task complete. ALWAYS notify when done (long tasks must notify)"
        echo "   - \`blocked\`: need human intervention. Describe what's blocking"
        echo "   - \`urgent\`: confirm before external actions. Describe what you're about to do"
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
            echo "  Go programs (glab etc.): use \`HTTPS_PROXY=${KYB_PROXY}\` (not ALL_PROXY)"
            if [ -n "${KYB_NO_PROXY:-}" ]; then
                echo "  (bypass: ${KYB_NO_PROXY})"
            fi
        fi

        echo ""
        echo "## Tailscale"
        echo "- Host Tailscale routes already reachable from container."
        echo "- **Do NOT install/configure Tailscale inside this container.**"
        echo "- SSH to target machines and run Tailscale commands there."
        echo "- If SSH via Tailscale IP fails, use public IP or fallback (e.g. sim 47.100.71.220)."
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

# Start PostgreSQL (skip in DID containers — host PG handles DB needs)
if [ -z "${KYB_DID:-}" ]; then
    pg_ctlcluster 16 main start 2>/dev/null || true
fi

# pip tools (may fail during image build, retry here at runtime)
# NOTE: Plaintext credentials below (readonlyuser:mimashishiliuwei) are known company tech debt.
# The credential has read-only Nexus access only; fixing it requires a company-wide
# credential management solution, not a local fix. See issue #108.
runuser -u dev -- bash -l -c "pip install -i 'https://readonlyuser:mimashishiliuwei@nexus.leyantech.com/repository/pypi-all/simple' mig25 mig25-codegen 'requests[socks]'" 2>/dev/null || true

# Install Claude Code at container start (avoids npm/SOCKS5 hang during build)
runuser -u dev -- bash -l -c '/home/dev/.local/bin/mise install npm:@anthropic-ai/claude-code@2 2>/dev/null' || true

# Claude Code native binary (postinstall may fail during image build)
runuser -u dev -- bash -l -c 'cmd=$(find /home/dev/.local/share/mise/installs/npm-anthropic-ai-claude-code -name install.cjs -path "*/@anthropic-ai/claude-code/*" 2>/dev/null | head -1); [ -n "$cmd" ] && node "$cmd" 2>/dev/null || true'

touch /tmp/kyb-ready

# Project setup: mise trust, npm install on first run
if [ -n "${KYB_PROJECT:-}" ] && [ -d "/home/dev/projects/${KYB_PROJECT}" ]; then
    runuser -u dev -- bash -l -s "${KYB_PROJECT:-}" << 'EOF'
        cd "/home/dev/projects/$1"
        # Trust system mise config first so mise activate works cleanly
        /home/dev/.local/bin/mise trust /home/dev/.config/mise/config.toml || true
        # Enable experimental plugins (swift, etc.)
        /home/dev/.local/bin/mise settings experimental=true 2>/dev/null || true
        eval "$(/home/dev/.local/bin/mise activate bash)"
        # Trust project-level mise config if any
        if [ -f mise.toml ]; then
            mise trust mise.toml || true
        fi

        # Node dependencies
        if [ -f package.json ] && { [ ! -d node_modules ] || [ -z "$(ls -A node_modules 2>/dev/null)" ]; }; then
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

# DID container: make dev toolchain available to root (Issue #11)
if [ -n "${KYB_DID:-}" ]; then
    # Symlink Maven config to root
    mkdir -p /root/.m2
    ln -sf /home/dev/.m2/settings.xml /root/.m2/settings.xml
    ln -sf /home/dev/.m2/repository /root/.m2/repository
    # Symlink Gradle cache to root
    ln -sf /home/dev/.gradle /root/.gradle
    # root's bashrc inherits dev's mise + PATH
    cat >> /root/.bashrc << 'ROOT_EOF'
export PATH="/home/dev/.local/bin:${PATH}"
eval "$(/home/dev/.local/bin/mise activate bash)"
ROOT_EOF
    # Trust mise config for root
    /home/dev/.local/bin/mise trust /home/dev/.config/mise/config.toml 2>/dev/null || true
    # ARM64 fallback
    if [ "$(uname -m)" = "aarch64" ]; then
        su - dev -c "mise install java@temurin-21 2>/dev/null || true" 2>/dev/null || true
    fi
fi

# Start cron daemon (for heartbeat and periodic tasks)
crond -b 2>/dev/null || true

# infra-boss: establish nuc8 SSH tunnel for GitLab proxy chain
if echo "$HOSTNAME" | grep -q "kyb-infra-boss"; then
  # Copy SSH keys to root (host mount is read-only)
  if [ -d /home/dev/.ssh-host ]; then
    mkdir -p /root/.ssh
    cp /home/dev/.ssh-host/id_rsa /root/.ssh/id_rsa 2>/dev/null || true
    cp /home/dev/.ssh-host/id_rsa_aliyun /root/.ssh/id_rsa_aliyun 2>/dev/null || true
    cp /home/dev/.ssh-host/config /root/.ssh/config 2>/dev/null || true
    chmod 600 /root/.ssh/id_rsa /root/.ssh/id_rsa_aliyun 2>/dev/null || true
  fi

  # Add nuc8-tunnel host config if not present
  if ! grep -q "nuc8-tunnel" /root/.ssh/config 2>/dev/null; then
    cat >> /root/.ssh/config << 'CONF'

Host nuc8-tunnel
  HostName 100.98.29.39
  User dongqs
  IdentityFile /root/.ssh/id_rsa
  StrictHostKeyChecking no
  ConnectTimeout 10
  ServerAliveInterval 15
  ServerAliveCountMax 3
  ExitOnForwardFailure yes
CONF
  fi

  # Install autossh if missing
  if ! command -v autossh >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq autossh 2>/dev/null || true
  fi

  # Start autossh tunnel (background, auto-reconnect)
  if ! ss -tlnp 2>/dev/null | grep -q :2081; then
    AUTOSSH_PIDFILE=/tmp/autossh-tunnel.pid \
    nohup autossh -M 0 \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=3 \
      -o ExitOnForwardFailure=yes \
      -L 0.0.0.0:2081:localhost:2081 \
      -N \
      nuc8-tunnel \
      > /dev/null 2>&1 &
  fi
fi

exec runuser -u dev -- "$@"
