FROM ubuntu:24.04

# Aliyun mirror for Ubuntu ARM (deb822 format)
RUN sed -i 's|http://ports.ubuntu.com/ubuntu-ports|http://mirrors.aliyun.com/ubuntu-ports|g' /etc/apt/sources.list.d/ubuntu.sources

RUN apt-get update && apt-get upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl wget git build-essential \
    libpq-dev libssl-dev libreadline-dev zlib1g-dev libffi-dev libyaml-dev \
    vim tmux htop gnupg unzip jq docker-compose-v2 \
    ripgrep fd-find fzf \
    docker.io sudo postgresql postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# PostgreSQL: trust local connections + Asia/Shanghai timezone (mig25 requirement)
RUN echo 'local all all trust' > /etc/postgresql/16/main/pg_hba.conf && \
    echo 'host all all 127.0.0.1/32 trust' >> /etc/postgresql/16/main/pg_hba.conf && \
    echo 'host all all ::1/128 trust' >> /etc/postgresql/16/main/pg_hba.conf && \
    echo "timezone = 'Asia/Shanghai'" >> /etc/postgresql/16/main/postgresql.conf

# UTF-8 locale (required by Ruby TOML parsing etc.)
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# Proxy: socks5 via OrbStack host, bypass intranet
ENV ALL_PROXY=socks5://host.orb.internal:2080 \
    all_proxy=socks5://host.orb.internal:2080 \
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

# mise global config — copied before GraalVM/mise-install so config changes
# only invalidate those two slow layers, not mise itself
COPY --chown=dev:dev mise.config.toml /home/dev/.config/mise/config.toml

# Pre-fetch GraalVM into mise cache (large tarball, retry-friendly)
RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    GRAALVM_DIR="/home/dev/.local/share/mise/downloads/java/graalvm-community-21.0.2" && \
    GRAALVM_FILE="graalvm-community-jdk-21.0.2_linux-aarch64_bin.tar.gz" && \
    if [ ! -f "$GRAALVM_DIR/$GRAALVM_FILE" ]; then \
        sudo mkdir -p "$GRAALVM_DIR" && \
        sudo chown -R dev:dev /home/dev/.local/share/mise && \
        curl -fsSL --retry 5 --retry-delay 15 \
            "https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-21.0.2/$GRAALVM_FILE" \
            -o "$GRAALVM_DIR/$GRAALVM_FILE"; \
    fi

# Install mise tools (node, python, claude-code, clickhouse, glab)
# Cache mount only covers downloads — installs/shim go into the image layer
SHELL ["/bin/bash", "-c"]
RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    mkdir -p /home/dev/.local/share/mise/downloads && \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    eval "$($HOME/.local/bin/mise activate bash)" && \
    mise trust && \
    mise install

# --- mirror configs (fast, rarely changes) — before slow project tools ---

# Gradle Nexus credentials (same readonly user as pip)
RUN mkdir -p ~/.gradle && \
    printf 'nexusUser=readonlyuser\nnexusPassword=mimashishiliuwei\n' > ~/.gradle/gradle.properties

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

USER root
# Clear proxy from final image — agent reads proxy config from CLAUDE.md
ENV ALL_PROXY= all_proxy= NO_PROXY= no_proxy=
COPY --chmod=+x entrypoint.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
