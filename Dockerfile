FROM ubuntu:24.04

# Proxy injected via --build-arg from `kyb build` (auto-detected on host).
# If empty (no proxy found), all downloads go direct.
ARG BUILD_ALL_PROXY=

# Aliyun mirror — supports both ARM64 (ports) and AMD64 (archive)
# TARGETARCH is auto-set by Docker BuildKit
RUN arch="${TARGETARCH:-$(uname -m)}" && \
    if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then \
        sed -i 's|http://ports.ubuntu.com/ubuntu-ports|http://mirrors.aliyun.com/ubuntu-ports|g' /etc/apt/sources.list.d/ubuntu.sources; \
    else \
        sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources; \
    fi

RUN apt-get update && apt-get upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl wget git build-essential \
    libpq-dev libssl-dev libreadline-dev zlib1g-dev libffi-dev libyaml-dev \
    librdkafka-dev \
    vim tmux htop gnupg unzip jq docker-compose-v2 \
    ripgrep fd-find fzf \
    lsof net-tools dnsutils iputils-ping traceroute tcpdump \
    docker.io docker-buildx sudo postgresql postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# PostgreSQL: trust local connections + Asia/Shanghai timezone (mig25 requirement)
RUN echo 'local all all trust' > /etc/postgresql/16/main/pg_hba.conf && \
    echo 'host all all 127.0.0.1/32 trust' >> /etc/postgresql/16/main/pg_hba.conf && \
    echo 'host all all ::1/128 trust' >> /etc/postgresql/16/main/pg_hba.conf && \
    echo "timezone = 'Asia/Shanghai'" >> /etc/postgresql/16/main/postgresql.conf

# UTF-8 locale (required by Ruby TOML parsing etc.)
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# Proxy: injected via --build-arg BUILD_ALL_PROXY from host auto-detection
ENV ALL_PROXY=${BUILD_ALL_PROXY} \
    all_proxy=${BUILD_ALL_PROXY} \
    NO_PROXY=.leyantech.com,git.leyantech.com,nexus.leyantech.com,localhost,127.0.0.1,host.orb.internal,.local,.internal \
    no_proxy=.leyantech.com,git.leyantech.com,nexus.leyantech.com,localhost,127.0.0.1,host.orb.internal,.local,.internal

# Create dev user (UID/GID adjusted at runtime by entrypoint)
# Remove default ubuntu user that occupies UID 1000
RUN userdel -r ubuntu 2>/dev/null; \
    useradd -m -s /bin/bash -G sudo dev && \
    echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev

USER dev
WORKDIR /home/dev

# Ensure ~/.local/bin is on PATH (mise, mig25, etc.)
ENV PATH="/home/dev/.local/bin:${PATH}"

# bash_profile / bashrc for mise activation (fast, rarely changes)
# Prepend mise activate BEFORE the Ubuntu default `[ -z "$PS1" ] && return`
# guard, so non-interactive shells (docker exec) get tools on PATH.
RUN echo '[ -f ~/.bashrc ] && . ~/.bashrc' > ~/.bash_profile && \
    { echo 'eval "$($HOME/.local/bin/mise activate bash)"'; \
      echo "alias claude='claude --dangerously-skip-permissions'"; \
      echo "alias fd=fdfind"; \
      cat ~/.bashrc; } > /tmp/bashrc.new && \
    mv /tmp/bashrc.new ~/.bashrc

# --- mise toolchain (slow, rarely changes beyond config.toml) ---

# Install mise (retry for network readiness)
RUN for i in 1 2 3 4 5; do \
      curl -sSL https://mise.run | sh && break; \
      sleep 5; \
    done

# mise global config
COPY --chown=dev:dev mise.config.toml /home/dev/.config/mise/config.toml

# Pre-create download cache dir (shared across all tool layers via cache mount)
RUN mkdir -p /home/dev/.local/share/mise/downloads && \
    sudo chown -R dev:dev /home/dev/.local/share/mise

# Install tools individually for independent layer caching.
# Order: stable (node/python/ruby) → medium (maven/glab/clickhouse) → volatile (claude-code)
# Each gets retry loop for transient network failures.
SHELL ["/bin/bash", "-c"]
RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    for i in 1 2 3; do /home/dev/.local/bin/mise install node@25 && break; sleep 5; done

RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    for i in 1 2 3; do /home/dev/.local/bin/mise install python@3.11 && break; sleep 5; done

RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    for i in 1 2 3; do /home/dev/.local/bin/mise install ruby@3.3 && break; sleep 5; done

RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    for i in 1 2 3; do /home/dev/.local/bin/mise install maven@3.9 && break; sleep 5; done

RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    for i in 1 2 3; do /home/dev/.local/bin/mise install glab@1.92 && break; sleep 5; done

RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    for i in 1 2 3; do /home/dev/.local/bin/mise install gh@latest && break; sleep 5; done

RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    for i in 1 2 3; do /home/dev/.local/bin/mise install clickhouse@26 && break; sleep 5; done

RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    for i in 1 2 3; do /home/dev/.local/bin/mise install npm:@anthropic-ai/claude-code@2 && break; sleep 5; done

RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    for i in 1 2 3; do /home/dev/.local/bin/mise install java@corretto-21 && break; sleep 5; done

RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    for i in 1 2 3; do /home/dev/.local/bin/mise install go@latest && break; sleep 5; done

RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    for i in 1 2 3; do /home/dev/.local/bin/mise install rust@latest && break; sleep 5; done

# --- mirror configs (fast, rarely changes) — before slow project tools ---

# Gradle Nexus credentials (same readonly user as pip)
RUN mkdir -p ~/.gradle && \
    printf 'nexusUser=readonlyuser\nnexusPassword=mimashishiliuwei\n' > ~/.gradle/gradle.properties

# Maven Nexus settings (with SNAPSHOT support for internal parent POMs)
RUN mkdir -p ~/.m2 && \
    cat > ~/.m2/settings.xml << 'XML'
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                      http://maven.apache.org/xsd/settings-1.0.0.xsd">
  <servers>
    <server>
      <id>nexus</id>
      <username>readonlyuser</username>
      <password>mimashishiliuwei</password>
    </server>
  </servers>
  <mirrors>
    <mirror>
      <id>nexus</id>
      <mirrorOf>*</mirrorOf>
      <url>https://nexus.leyantech.com/repository/maven-public/</url>
    </mirror>
  </mirrors>
  <profiles>
    <profile>
      <id>nexus</id>
      <activation><activeByDefault>true</activeByDefault></activation>
      <repositories>
        <repository>
          <id>nexus</id>
          <url>https://nexus.leyantech.com/repository/maven-public/</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </repository>
      </repositories>
    </profile>
  </profiles>
</settings>
XML

# Mirror configs for package managers
RUN mkdir -p ~/.pip && \
    echo 'registry=https://registry.npmmirror.com' > ~/.npmrc && \
    printf '%s\n' '---' 'sources:' '  - https://gems.ruby-china.com' > ~/.gemrc && \
    printf '%s\n' '[global]' 'index-url = https://mirrors.aliyun.com/pypi/simple/' > ~/.pip/pip.conf

RUN eval "$($HOME/.local/bin/mise activate bash)" && \
    bundle config set --global mirror.https://rubygems.org https://gems.ruby-china.com && \
    npm install -g yarn

RUN mkdir -p /home/dev/projects

# --- project tools (slow, changes more often) ---

# mig25 — PostgreSQL migration toolkit (needs mise Python on PATH)
RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    --mount=type=cache,target=/home/dev/.cache/pip \
    mkdir -p /home/dev/.local/share/mise/downloads /home/dev/.cache/pip && \
    sudo chown -R dev:dev /home/dev/.local/share/mise /home/dev/.cache/pip && \
    eval "$($HOME/.local/bin/mise activate bash)" && \
    pip install -i 'https://readonlyuser:mimashishiliuwei@nexus.leyantech.com/repository/pypi-all/simple' mig25 mig25-codegen 'requests[socks]' -U || true

# kimi-cli — Moonshot AI coding agent (installs uv + kimi)
ARG KIMI_VERSION=1.43.0
RUN --mount=type=cache,target=/home/dev/.cache/uv \
    sudo mkdir -p /home/dev/.cache/uv /home/dev/.local/share/uv && \
    sudo chown -R dev:dev /home/dev/.cache/uv /home/dev/.local/share && \
    curl -fsSL https://code.kimi.com/install.sh | bash

# Replace uv-managed kimi symlink with wrapper that sanitizes NO_PROXY
RUN rm -f /home/dev/.local/bin/kimi
COPY --chown=dev:dev --chmod=+x kimi-wrapper /home/dev/.local/bin/kimi

# Playwright for E2E testing (Chromium browser + system deps)
# + puppeteer for headless screenshot (reuses same Chromium)
# ALL_PROXY cleared: Aliyun PyPI mirror doesn't need SOCKS proxy
RUN --mount=type=cache,target=/home/dev/.cache/pip \
    --mount=type=cache,target=/home/dev/.cache/ms-playwright \
    sudo mkdir -p /home/dev/.cache/ms-playwright && \
    sudo chown -R dev:dev /home/dev/.cache/pip /home/dev/.cache/ms-playwright && \
    eval "$($HOME/.local/bin/mise activate bash)" && \
    ALL_PROXY="" all_proxy="" pip install playwright && \
    python -m playwright install chromium --with-deps && \
    PUPPETEER_SKIP_DOWNLOAD=true npm install -g puppeteer

# kyb CLI for notify command (copy lib, create wrapper script)
COPY --chown=dev:dev lib /home/dev/.kyb/lib
RUN mkdir -p /home/dev/.kyb/bin && \
    printf '#!/usr/bin/env ruby\n$LOAD_PATH.unshift("/home/dev/.kyb/lib")\nrequire "kyb"\nKyb::CLI.dispatch(ARGV)\n' \
    > /home/dev/.kyb/bin/kyb && \
    chmod +x /home/dev/.kyb/bin/kyb && \
    ln -s /home/dev/.kyb/bin/kyb /home/dev/.local/bin/kyb

USER root
# Clear proxy from final image — agent reads proxy config from CLAUDE.md
ENV ALL_PROXY= all_proxy= NO_PROXY= no_proxy=
COPY --chmod=+x entrypoint.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
