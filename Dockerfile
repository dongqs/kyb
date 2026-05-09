FROM ubuntu:24.04

# Aliyun mirror for Ubuntu ARM (deb822 format)
RUN sed -i 's|http://ports.ubuntu.com/ubuntu-ports|http://mirrors.aliyun.com/ubuntu-ports|g' /etc/apt/sources.list.d/ubuntu.sources

RUN apt-get update && apt-get upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl wget git build-essential \
    libpq-dev libssl-dev libreadline-dev zlib1g-dev \
    vim tmux htop gnupg unzip jq docker-compose-v2 \
    docker.io sudo postgresql postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# PostgreSQL: trust local connections + Asia/Shanghai timezone (mig25 requirement)
RUN echo 'local all all trust' > /etc/postgresql/16/main/pg_hba.conf && \
    echo 'host all all 127.0.0.1/32 trust' >> /etc/postgresql/16/main/pg_hba.conf && \
    echo 'host all all ::1/128 trust' >> /etc/postgresql/16/main/pg_hba.conf && \
    echo "timezone = 'Asia/Shanghai'" >> /etc/postgresql/16/main/postgresql.conf

# Proxy: socks5 via OrbStack host, bypass intranet
ENV ALL_PROXY=socks5://host.orb.internal:2080 \
    all_proxy=socks5://host.orb.internal:2080 \
    NO_PROXY=.leyantech.com,git.leyantech.com,nexus.leyantech.com,localhost,127.0.0.1,host.orb.internal,.local,.internal \
    no_proxy=.leyantech.com,git.leyantech.com,nexus.leyantech.com,localhost,127.0.0.1,host.orb.internal,.local,.internal

# Create dev user (UID/GID adjusted at runtime by entrypoint)
RUN useradd -m -s /bin/bash -G sudo dev && \
    echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev

USER dev
WORKDIR /home/dev

# Ensure ~/.local/bin is on PATH (mise, mig25, etc.)
ENV PATH="/home/dev/.local/bin:${PATH}"

# Install mise (retry for network readiness)
RUN for i in 1 2 3 4 5; do \
      curl -sSL https://mise.run | sh && break; \
      sleep 5; \
    done

# bash_profile / bashrc for mise activation
RUN echo '[ -f ~/.bashrc ] && . ~/.bashrc' > ~/.bash_profile && \
    echo 'eval "$($HOME/.local/bin/mise activate bash)"' >> ~/.bashrc

# mise global config
COPY --chown=dev:dev mise.config.toml /home/dev/.config/mise/config.toml

# Install mise tools (node, python, claude-code, clickhouse, glab)
# Cache mount persists mise downloads/installs across builds
SHELL ["/bin/bash", "-c"]
RUN --mount=type=cache,target=/home/dev/.local/share/mise \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    eval "$($HOME/.local/bin/mise activate bash)" && \
    mise install

# mig25 — PostgreSQL migration toolkit (needs mise Python on PATH)
RUN --mount=type=cache,target=/home/dev/.local/share/mise \
    --mount=type=cache,target=/home/dev/.cache/pip \
    sudo chown -R dev:dev /home/dev/.local/share/mise /home/dev/.cache/pip && \
    eval "$($HOME/.local/bin/mise activate bash)" && \
    pip install -i 'https://readonlyuser:mimashishiliuwei@nexus.leyantech.com/repository/pypi-all/simple' mig25 -U

# Mirror configs for package managers
RUN mkdir -p ~/.pip && \
    echo 'registry=https://registry.npmmirror.com' > ~/.npmrc && \
    printf '%s\n' '---' 'sources:' '  - https://gems.ruby-china.com' > ~/.gemrc && \
    printf '%s\n' '[global]' 'index-url = https://mirrors.aliyun.com/pypi/simple/' > ~/.pip/pip.conf

# Sandbox reference (for Claude Code inside container)
COPY CLAUDE.sandbox.md /home/dev/CLAUDE.md

USER root
COPY --chmod=+x entrypoint.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
