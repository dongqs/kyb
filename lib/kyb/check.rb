# frozen_string_literal: true

module Kyb::Check
  ENDPOINTS = {
    'Aliyun mirror'           => URI('https://mirrors.aliyun.com'),
    'npmmirror'               => URI('https://npmmirror.com'),
    'mise.run'                => URI('https://mise.run'),
    'Node mirror'             => URI('https://npmmirror.com/mirrors/node'),
    'Python (python.org)'     => URI('https://www.python.org'),
    'Ruby (cache.ruby-lang)'  => URI('https://cache.ruby-lang.org'),
  }.freeze

  CONFIG_HINT = "  Config: ~/.config/kyb/config.yml\n  Dockerfile: ~/.kyb/Dockerfile (ALL_PROXY line)".freeze

  module_function

  def run_checks
    proxy = Kyb::Proxy.detect

    results = []
    results << check_ruby
    results << check_docker
    results << check_proxy(proxy) if proxy
    results += ENDPOINTS.map { |name, uri| check_endpoint(name, uri.to_s, proxy) }
    results << check_disk

    failed = results.reject { |r| r[:ok] }

    puts "\n==> Pre-flight checks: #{failed.empty? ? 'ALL PASS' : "#{failed.size} FAILED"}"
    results.each do |r|
      icon = r[:ok] ? '  OK' : 'FAIL'
      proxy_tag = r[:via_proxy] ? ' (via proxy)' : ''
      puts "  [#{icon}] #{r[:name]}#{proxy_tag} — #{r[:msg]}"
      puts "       #{r[:hint]}" if r[:hint]
    end

    puts "  [INFO] Proxy source: #{proxy ? proxy : '(none)'}"
    if proxy
      src = config_proxy_source
      puts "  [INFO] Proxy source: #{src}" if src
    end

    return if failed.empty?

    puts "\n  Fix the above failures, then re-run: kyb preflight"
    Kyb.die("pre-flight check: #{failed.map { |r| r[:name] }.join(', ')}")
  end

  def config_proxy_source
    return 'config.yml' if Kyb::Proxy.config_proxy
    return 'env var' if Kyb::Proxy.env_proxy
    'port probe'
  end

  def check_proxy(proxy)
    uri = URI.parse(proxy)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Socket.tcp(uri.host, uri.port, connect_timeout: 5) { |s| s.close }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    @proxy_reachable = true
    { name: 'Proxy server', ok: true, msg: "#{proxy}  (#{elapsed.round(2)}s)" }
  rescue => e
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    @proxy_reachable = false
    { name: 'Proxy server', ok: false, msg: "#{e.class.name.split('::').last} (#{elapsed.round(2)}s)",
      hint: "Proxy not reachable: #{proxy}\n       Set proxy in ~/.config/kyb/config.yml:\n         base:\n           proxy: socks5://your-proxy:port" }
  end

  def proxy_reachable?
    @proxy_reachable == true
  end

  def check_docker
    out = `docker info --format '{{.ServerVersion}}' 2>&1`.strip
    if $?.success?
      { name: 'Docker daemon', ok: true, msg: "v#{out}" }
    else
      { name: 'Docker daemon', ok: false, msg: out.lines.first&.strip || 'not running' }
    end
  end

  def check_ruby
    version = RUBY_VERSION
    major, minor = version.split('.').map(&:to_i)
    ok = major >= 3
    msg = ok ? "v#{version} ✓" : "v#{version} ✗ (need >= 3.0, upgrade via brew install ruby)"
    { name: 'Ruby version', ok: ok, msg: msg }
  end

  def check_endpoint(name, url, proxy)
    result = try_http_direct(name, url)
    return result if result[:ok]

    if proxy
      proxy_result = try_http_via_proxy(name, url, proxy)
      return proxy_result if proxy_result[:ok]
    end

    # Failed both direct and proxy — add hint
    if proxy
      result[:hint] = "Direct and proxy (#{proxy}) both failed.\n       Check your proxy: #{CONFIG_HINT}"
    else
      result[:hint] = 'No proxy configured for build. Try setting up a SOCKS5 proxy.' unless result[:ok]
    end
    result
  end

  def try_http_direct(name, url)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 6
    http.read_timeout = 6
    http.use_ssl = uri.scheme == 'https'
    path = uri.path.empty? ? '/' : uri.path
    resp = http.request_head(path)
    resp = http.request_get(path) if resp.is_a?(Net::HTTPMethodNotAllowed)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    ok = resp.is_a?(Net::HTTPOK) || resp.is_a?(Net::HTTPRedirection)
    { name: name, ok: ok, msg: "#{resp.code}  (#{elapsed.round(2)}s)", via_proxy: false }
  rescue => e
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    { name: name, ok: false, msg: "#{e.class.name.split('::').last} (#{elapsed.round(2)}s)", via_proxy: false }
  end

  def try_http_via_proxy(name, url, proxy)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = `curl -sS -o /dev/null -w '%{http_code}' --proxy '#{proxy}' --max-time 12 '#{url}' 2>&1`.strip
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    ok = out == '200' || out == '301' || out == '302' || out == '307'
    { name: name, ok: ok, msg: "#{out}  (#{elapsed.round(2)}s)", via_proxy: true }
  rescue => e
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    { name: name, ok: false, msg: e.message, via_proxy: true }
  end

  def check_disk
    out = `df -BG / 2>/dev/null`.lines[1]
    if out
      avail = out.split[3]
      { name: 'Disk space (/)', ok: true, msg: "#{avail} available" }
    else
      { name: 'Disk space (/)', ok: true, msg: 'unknown' }
    end
  rescue => e
    { name: 'Disk space (/)', ok: true, msg: e.message }
  end
end
