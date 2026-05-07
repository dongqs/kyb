FROM ubuntu:24.04

# Aliyun mirror for Ubuntu ARM (deb822 format)
RUN sed -i 's|http://ports.ubuntu.com/ubuntu-ports|http://mirrors.aliyun.com/ubuntu-ports|g' /etc/apt/sources.list.d/ubuntu.sources

RUN apt-get update && apt-get upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl wget git build-essential \
    libpq-dev libssl-dev libreadline-dev zlib1g-dev \
    vim tmux htop gnupg unzip jq docker-compose-v2 \
    docker.io sudo \
    && rm -rf /var/lib/apt/lists/*

# Proxy: socks5 via OrbStack host, bypass intranet
ENV ALL_PROXY=socks5://host.orb.internal:2080 \
    all_proxy=socks5://host.orb.internal:2080 \
    NO_PROXY=git.leyantech.com,localhost,127.0.0.1,host.orb.internal,.local,.internal \
    no_proxy=git.leyantech.com,localhost,127.0.0.1,host.orb.internal,.local,.internal

# Create dev user (UID/GID adjusted at runtime by entrypoint)
RUN useradd -m -s /bin/bash -G sudo dev && \
    echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev

USER dev
WORKDIR /home/dev

# Install mise (retry for network readiness)
RUN for i in 1 2 3 4 5; do \
      curl -sSL https://mise.run | sh && break; \
      sleep 5; \
    done

# bash_profile sources bashrc for login shells (mise activation)
RUN echo '[ -f ~/.bashrc ] && . ~/.bashrc' > ~/.bash_profile

# mise activation in bashrc
RUN echo 'eval "$($HOME/.local/bin/mise activate bash)"' >> ~/.bashrc

# Node LTS via mise
RUN eval "$($HOME/.local/bin/mise activate bash)" && \
    mise use -g node@lts

# Claude Code
RUN eval "$($HOME/.local/bin/mise activate bash)" && \
    npm install -g @anthropic-ai/claude-code

# Mirror configs
RUN mkdir -p ~/.pip && \
    echo 'registry=https://registry.npmmirror.com' > ~/.npmrc && \
    printf '---\nsources:\n  - https://gems.ruby-china.com\n' > ~/.gemrc && \
    printf '[global]\nindex-url = https://mirrors.aliyun.com/pypi/simple/\n' > ~/.pip/pip.conf

COPY entrypoint.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
