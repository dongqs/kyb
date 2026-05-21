# frozen_string_literal: true

module Kyb::Proxy
  COMMON_PROXIES = [
    'socks5://host.orb.internal:2080',
    'socks5://localhost:1080',
    'socks5://127.0.0.1:7890',
    'http://127.0.0.1:7890',
    'socks5://127.0.0.1:7897',
    'socks5://localhost:10808',
  ].freeze

  ENV_VARS = %w[ALL_PROXY HTTPS_PROXY HTTP_PROXY].freeze

  module_function

  def detect
    cfg = config_proxy
    return cfg if cfg

    env = env_proxy
    return env if env

    probe
  end

  def config_proxy
    proxy = Kyb::Config.proxy
    return nil unless proxy

    uri = URI.parse(proxy)
    # Inside Docker containers (kyb sandbox), 127.0.0.1/localhost refer to the
    # container itself, not the host machine. Translate to host.orb.internal
    # which resolves to the macOS host (works on both Orbstack and Docker Desktop).
    if %w[127.0.0.1 localhost].include?(uri.host) && docker_container?
      proxy.sub(uri.host, 'host.orb.internal')
    else
      proxy
    end
  rescue
    nil
  end

  def docker_container?
    Kyb.in_container?
  end

  def env_proxy
    ENV_VARS.each do |var|
      val = ENV[var]
      return val if val && !val.strip.empty?
    end
    nil
  end

  def probe
    COMMON_PROXIES.each do |proxy|
      uri = URI.parse(proxy)
      Socket.tcp(uri.host, uri.port, connect_timeout: 1) { |s| s.close }
      return proxy
    rescue
      next
    end
    nil
  end
end
