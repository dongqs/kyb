# frozen_string_literal: true

require 'open3'

module Kyb::Check
  CmdResult = Struct.new(:output, :success?)

  ENDPOINTS = {
    'Aliyun mirror'           => URI('https://mirrors.aliyun.com'),
    'npmmirror'               => URI('https://npmmirror.com'),
    'mise.run'                => URI('https://mise.run'),
    'Node mirror'             => URI('https://npmmirror.com/mirrors/node'),
    'Python (python.org)'     => URI('https://www.python.org'),
    'Ruby (cache.ruby-lang)'  => URI('https://cache.ruby-lang.org'),
  }.freeze

  def run_checks
    proxy = Kyb::Proxy.detect

    results = []

    results << check_ruby
    print_result(results.last)

    results << check_docker
    print_result(results.last)

    if proxy
      results << check_proxy(proxy)
      print_result(results.last)
    end

    ENDPOINTS.each do |name, uri|
      results << check_endpoint(name, uri.to_s, proxy)
      print_result(results.last)
    end

    results << check_disk
    print_result(results.last)

    failed = results.reject { |r| r[:ok] }

    puts "\n==> Pre-flight checks: #{failed.empty? ? 'ALL PASS' : "#{failed.size} FAILED"}"
    print_proxy_info(proxy, failed)
    print_proxy_hint(proxy, failed)

    return if failed.empty?

    puts "\n  Fix the above failures, then re-run: kyb preflight"
    Kyb.die("pre-flight check: #{failed.map { |r| r[:name] }.join(', ')}")
  end

  def print_result(r)
    icon = r[:ok] ? '  OK' : 'FAIL'
    proxy_tag = r[:via_proxy] ? ' (via proxy)' : ''
    puts "  [#{icon}] #{r[:name]}#{proxy_tag} — #{r[:msg]}"
    puts "       #{r[:hint]}" if r[:hint]
  end

  def print_proxy_info(proxy, _failed)
    if proxy
      puts "  [INFO] Proxy: #{proxy}  (#{proxy_source})"
    else
      puts '  [INFO] Proxy: none detected'
    end
  end

  def print_proxy_hint(proxy, failed)
    return if proxy || failed.empty?

    puts <<~HINT

      ── Proxy Setup ──────────────────────────────────
      Some endpoints failed because they need a proxy to
      reach international download sites from China.

      Option A — Start your proxy software (sing-box, Clash, etc.)
        then re-run: kyb preflight

      Option B — Configure a proxy address manually:
        Edit ~/.config/kyb/config.yml:
          base:
            proxy: socks5://127.0.0.1:7890

      Option C — If you're on an internal network that
        doesn't need a proxy, these endpoints will still
        fail but kyb build may still work with mirrors:
        kyb build
      ─────────────────────────────────────────────────
    HINT
  end

  def proxy_source
    return 'config.yml' if Kyb::Proxy.config_proxy
    return 'env var' if Kyb::Proxy.env_proxy
    'port probe'
  end

  def check_proxy(proxy)
    uri = URI.parse(proxy)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Socket.tcp(uri.host, uri.port, connect_timeout: 5) { |s| s.close }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    { name: 'Proxy server', ok: true, msg: "#{proxy}  (#{elapsed.round(2)}s)" }
  rescue => e
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    { name: 'Proxy server', ok: false, msg: "#{e.class.name.split('::').last} (#{elapsed.round(2)}s)",
      hint: "Cannot reach #{proxy}.\n       Edit proxy address in ~/.config/kyb/config.yml:\n         base:\n           proxy: socks5://your-proxy:port" }
  end

  def check_docker
    out, _stderr, status = Open3.capture3('docker', 'info', '--format', '{{.ServerVersion}}')
    out = out.strip
    if status.success?
      { name: 'Docker daemon', ok: true, msg: "v#{out}" }
    else
      { name: 'Docker daemon', ok: false, msg: out.lines.first&.strip || 'not running' }
    end
  end

  def check_ruby
    version = RUBY_VERSION
    major = version.split('.').first.to_i
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

    if proxy
      result[:hint] = "Direct and proxy (#{proxy}) both failed.\n       Check proxy address in ~/.config/kyb/config.yml"
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
    stdout, stderr, status = Open3.capture3('curl', '-sS', '-o', '/dev/null', '-w', '%{http_code}',
                                            '--proxy', proxy, '--max-time', '12', url)
    out = (status.success? ? stdout : stderr).strip
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    ok = out == '200' || out == '301' || out == '302' || out == '307'
    { name: name, ok: ok, msg: "#{out}  (#{elapsed.round(2)}s)", via_proxy: true }
  rescue => e
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    { name: name, ok: false, msg: e.message, via_proxy: true }
  end

  def check_disk
    out, _stderr, status = Open3.capture3('df', '-h', '/')
    line = status.success? ? out.lines[1] : nil
    if line
      avail = line.split[3]
      { name: 'Disk space (/)', ok: true, msg: "#{avail} available" }
    else
      { name: 'Disk space (/)', ok: true, msg: 'unknown' }
    end
  rescue Errno::ENOENT => e
    { name: 'Disk space (/)', ok: true, msg: e.message }
  end

  # ---------------------------------------------------------------------------
  # Onboarding assertion helpers — called by agent to detect/fix env issues
  # ---------------------------------------------------------------------------

  def assert_java(expected_version: '21')
    result = capture_cmd("java -version 2>&1")

    unless result.success?
      puts "❌ Java not installed"
      install_result = capture_cmd("mise install java@corretto-#{expected_version} && mise use -g java@corretto-#{expected_version} 2>&1")
      unless install_result.success?
        return false
      end
      result = capture_cmd("mise x java -- java -version 2>&1")
    end

    if result.output.include?(expected_version)
      java_home = capture_cmd("mise x java -- sh -c 'echo $JAVA_HOME' 2>&1")
      if java_home.output.strip.empty?
        java_home_path = capture_cmd("mise where java 2>&1")
        ENV['JAVA_HOME'] = java_home_path.output.strip if java_home_path.success?
      end
      puts "✅ Java #{expected_version}"
      true
    else
      switch_result = capture_cmd("mise use -g java@corretto-#{expected_version} 2>&1")
      if switch_result.success?
        result = capture_cmd("mise x java -- java -version 2>&1")
        if result.output.include?(expected_version)
          puts "✅ Java #{expected_version}"
          return true
        end
      end
      version_str = result.output.lines.first&.strip || 'unknown'
      puts "❌ Java version mismatch: expected #{expected_version}, got #{version_str}"
      false
    end
  end

  def assert_pg
    ready = capture_cmd("pg_isready -q 2>&1")
    if ready.success?
      puts "✅ PostgreSQL is running"
      return true
    end

    start_result = capture_cmd("pg_ctlcluster 16 main start 2>&1")
    if start_result.success?
      5.times do
        sleep 1
        ready = capture_cmd("pg_isready -q 2>&1")
        if ready.success?
          puts "✅ PostgreSQL started"
          return true
        end
      end
    end

    puts "❌ PostgreSQL failed to start"
    false
  end

  def assert_mise_tool(tool_name)
    # Check if tool is already available on PATH
    which_result = capture_cmd("which #{tool_name} 2>&1")
    if which_result.success?
      puts "✅ #{tool_name} available"
      return true
    end

    # Install via mise
    install_result = capture_cmd("mise install #{tool_name} 2>&1")
    unless install_result.success?
      puts "❌ #{tool_name} not found"
      return false
    end

    # Activate globally (required so shims work in subsequent sessions)
    capture_cmd("mise use -g #{tool_name} 2>&1")

    # Verify with mise x (works in non-interactive shells unlike bare `which`)
    verify = capture_cmd("mise x #{tool_name} -- #{tool_name} --version 2>&1")
    if verify.success?
      puts "✅ #{tool_name} available"
      return true
    end

    puts "❌ #{tool_name} not found"
    false
  end

  def capture_cmd(cmd)
    output, _stderr, status = Open3.capture3('sh', '-c', cmd)
    CmdResult.new(output, status.success?)
  end

  module_function :run_checks, :print_result, :print_proxy_info, :print_proxy_hint,
                   :proxy_source, :check_proxy, :check_docker, :check_ruby,
                   :check_endpoint, :try_http_direct, :try_http_via_proxy, :check_disk,
                   :assert_java, :assert_pg, :assert_mise_tool, :capture_cmd
end
