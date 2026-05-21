# frozen_string_literal: true

require_relative 'test_helper'

class CheckTest < Minitest::Test
  # --- Ruby ---

  def test_check_ruby
    result = Kyb::Check.check_ruby
    assert result[:ok], "Ruby version check: #{result[:msg]}"
    assert_match(/v3\.\d/, result[:msg])
  end

  # --- Docker ---

  def test_check_docker
    skip 'Docker not available in CI' if ENV['CI']
    result = Kyb::Check.check_docker
    assert result[:ok], "Docker should be available: #{result[:msg]}"
    assert_match(/v\d/, result[:msg])
  end

  # --- Disk ---

  def test_check_disk
    result = Kyb::Check.check_disk
    assert result[:ok]
    assert_match(/available/, result[:msg])
  end

  # --- Proxy detect ---

  def test_proxy_detect
    skip 'Proxy not configured in CI' if ENV['CI']
    proxy = Kyb::Proxy.detect
    refute_nil proxy, 'should detect a proxy'
    assert_match(%r{socks5://|http://}, proxy)
  end

  def test_proxy_env_vars
    orig = ENV['ALL_PROXY']
    ENV['ALL_PROXY'] = 'socks5://test:1080'
    assert_equal 'socks5://test:1080', Kyb::Proxy.env_proxy
  ensure
    ENV['ALL_PROXY'] = orig
  end

  def test_proxy_env_vars_custom_var
    orig = ENV['HTTPS_PROXY']
    ENV['HTTPS_PROXY'] = 'http://proxy:3128'
    assert_equal 'http://proxy:3128', Kyb::Proxy.env_proxy
  ensure
    ENV['HTTPS_PROXY'] = orig
  end

  def test_proxy_env_vars_priority
    orig_c = Kyb::Proxy.method(:config_proxy)
    Kyb::Proxy.define_singleton_method(:config_proxy) { nil }
    orig_a = ENV['ALL_PROXY']
    orig_h = ENV['HTTPS_PROXY']
    ENV['ALL_PROXY'] = 'socks5://all:1080'
    ENV['HTTPS_PROXY'] = 'http://https:3128'
    assert_equal 'socks5://all:1080', Kyb::Proxy.detect
  ensure
    ENV['ALL_PROXY'] = orig_a
    ENV['HTTPS_PROXY'] = orig_h
    Kyb::Proxy.define_singleton_method(:config_proxy, orig_c)
  end

  def test_proxy_config_override_env
    # config_proxy has highest priority
    orig_config = Kyb::Proxy.method(:config_proxy)
    Kyb::Proxy.define_singleton_method(:config_proxy) { 'socks5://config:2080' }
    orig_a = ENV['ALL_PROXY']
    ENV['ALL_PROXY'] = 'socks5://env:1080'
    assert_equal 'socks5://config:2080', Kyb::Proxy.detect
  ensure
    ENV['ALL_PROXY'] = orig_a
    Kyb::Proxy.define_singleton_method(:config_proxy, orig_config)
  end

  # --- Proxy server reachability ---

  def test_check_proxy_reachable
    proxy = Kyb::Proxy.detect
    skip 'no proxy to test' unless proxy
    uri = URI.parse(proxy)
    begin
      Socket.tcp(uri.host, uri.port, connect_timeout: 2) { |s| s.close }
    rescue => e
      skip "proxy #{proxy} not reachable: #{e.message}"
    end
    result = Kyb::Check.check_proxy(proxy)
    assert result[:ok], "proxy should be reachable: #{result[:msg]}"
  end

  def test_check_proxy_unreachable
    result = Kyb::Check.check_proxy('socks5://127.0.0.1:1')
    refute result[:ok], 'port 1 should be unreachable'
    assert result[:hint], 'should give config hint'
    assert_match(/config\.yml/, result[:hint])
  end

  # --- Endpoint checks ---

  def test_check_endpoint_direct_ok
    result = Kyb::Check.check_endpoint('test', 'https://npmmirror.com', nil)
    assert result[:ok], "direct should work: #{result[:msg]}"
  end

  def test_check_endpoint_direct_fail_no_proxy
    result = Kyb::Check.check_endpoint('test', 'https://127.0.0.1:1', nil)
    refute result[:ok]
  end

  def test_check_endpoint_fallback_to_proxy
    proxy = Kyb::Proxy.detect
    skip 'no proxy for fallback test' unless proxy
    result = Kyb::Check.check_endpoint('test', 'https://www.python.org', proxy)
    skip "proxy/network dependent: #{result[:msg]}" unless result[:ok]
  end

  # --- try_http_direct ---

  def test_try_http_direct_aliyun
    result = Kyb::Check.try_http_direct('Aliyun', 'https://mirrors.aliyun.com')
    assert result[:ok], "Aliyun mirror: #{result[:msg]}"
  end

  def test_try_http_direct_npmmirror
    result = Kyb::Check.try_http_direct('npmmirror', 'https://npmmirror.com')
    assert result[:ok], "npmmirror: #{result[:msg]}"
  end

  def test_try_http_direct_miserun
    result = Kyb::Check.try_http_direct('mise.run', 'https://mise.run')
    assert result[:ok], "mise.run: #{result[:msg]}"
  end

  def test_try_http_direct_failure
    result = Kyb::Check.try_http_direct('bogus', 'https://127.0.0.1:1')
    refute result[:ok]
    refute result[:via_proxy]
  end

  # --- try_http_via_proxy ---

  def test_try_http_via_proxy
    proxy = Kyb::Proxy.detect
    skip 'no proxy for via-proxy test' unless proxy
    uri = URI.parse(proxy)
    begin
      Socket.tcp(uri.host, uri.port, connect_timeout: 2) { |s| s.close }
    rescue => e
      skip "proxy #{proxy} not reachable: #{e.message}"
    end
    result = Kyb::Check.try_http_via_proxy('test', 'https://npmmirror.com', proxy)
    assert result[:ok], "via proxy: #{result[:msg]}"
    assert result[:via_proxy]
  end

  def test_try_http_via_proxy_failure
    result = Kyb::Check.try_http_via_proxy('test', 'https://127.0.0.1:1', 'socks5://127.0.0.1:1')
    refute result[:ok]
    assert result[:via_proxy]
  end

  # --- proxy_source ---

  def test_proxy_source_config
    orig = Kyb::Proxy.method(:config_proxy)
    Kyb::Proxy.define_singleton_method(:config_proxy) { 'socks5://test:1080' }
    assert_equal 'config.yml', Kyb::Check.proxy_source
  ensure
    Kyb::Proxy.define_singleton_method(:config_proxy, orig)
  end

  def test_proxy_source_env
    orig_c = Kyb::Proxy.method(:config_proxy)
    orig_e = Kyb::Proxy.method(:env_proxy)
    Kyb::Proxy.define_singleton_method(:config_proxy) { nil }
    Kyb::Proxy.define_singleton_method(:env_proxy) { 'socks5://test:1080' }
    assert_equal 'env var', Kyb::Check.proxy_source
  ensure
    Kyb::Proxy.define_singleton_method(:config_proxy, orig_c)
    Kyb::Proxy.define_singleton_method(:env_proxy, orig_e)
  end

  def test_proxy_source_probe
    orig_c = Kyb::Proxy.method(:config_proxy)
    orig_e = Kyb::Proxy.method(:env_proxy)
    Kyb::Proxy.define_singleton_method(:config_proxy) { nil }
    Kyb::Proxy.define_singleton_method(:env_proxy) { nil }
    assert_equal 'port probe', Kyb::Check.proxy_source
  ensure
    Kyb::Proxy.define_singleton_method(:config_proxy, orig_c)
    Kyb::Proxy.define_singleton_method(:env_proxy, orig_e)
  end
end

class CheckAssertTest < Minitest::Test
  CmdResult = Kyb::Check::CmdResult

  def setup
    @orig_capture = Kyb::Check.method(:capture_cmd)
  end

  def teardown
    Kyb::Check.define_singleton_method(:capture_cmd, @orig_capture)
  end

  # --- assert_java ---

  def test_assert_java_version_match
    Kyb::Check.define_singleton_method(:capture_cmd) do |cmd|
      case cmd
      when 'java -version 2>&1'
        CmdResult.new(%(openjdk version "21.0.1" 2023-10-17\n), true)
      when /\Amise x java -- sh -c/
        CmdResult.new("/usr/lib/jvm/java-21-openjdk\n", true)
      else
        CmdResult.new("", false)
      end
    end

    out, _err = capture_io do
      assert Kyb::Check.assert_java
    end
    assert_match(/✅ Java 21/, out)
  end

  def test_assert_java_not_installed_then_installed
    call_count = 0
    Kyb::Check.define_singleton_method(:capture_cmd) do |cmd|
      call_count += 1
      case cmd
      when 'java -version 2>&1'
        if call_count <= 1
          CmdResult.new("java: command not found\n", false)
        else
          CmdResult.new(%(openjdk version "21.0.1" 2023-10-17\n), true)
        end
      when /\Amise install java/
        CmdResult.new("", true)
      when /\Amise use -g java/
        CmdResult.new("", true)
      when /\Amise x java -- java -version/
        CmdResult.new(%(openjdk version "21.0.1" 2023-10-17\n), true)
      when /\Amise x java -- sh -c/
        CmdResult.new("/usr/lib/jvm/java-21-openjdk\n", true)
      when 'echo $JAVA_HOME'
        CmdResult.new("", true)
      when /\Amise where java/
        CmdResult.new("/home/dev/.local/share/mise/installs/java/21\n", true)
      else
        CmdResult.new("", false)
      end
    end

    out, _err = capture_io do
      assert Kyb::Check.assert_java
    end
    assert_match(/✅ Java 21/, out)
  end

  def test_assert_java_version_mismatch_then_switched
    java_count = 0
    Kyb::Check.define_singleton_method(:capture_cmd) do |cmd|
      case cmd
      when 'java -version 2>&1'
        java_count += 1
        if java_count == 1
          CmdResult.new(%(openjdk version "17.0.1" 2023-10-17\n), true)
        else
          CmdResult.new(%(openjdk version "21.0.1" 2023-10-17\n), true)
        end
      when /\Amise use -g java/
        CmdResult.new("", true)
      when /\Amise x java -- java -version/
        CmdResult.new(%(openjdk version "21.0.1" 2023-10-17\n), true)
      when /\Amise x java -- sh -c/
        CmdResult.new("/usr/lib/jvm/java-21-openjdk\n", true)
      when 'echo $JAVA_HOME'
        CmdResult.new("", true)
      when /\Amise where java/
        CmdResult.new("/home/dev/.local/share/mise/installs/java/21\n", true)
      else
        CmdResult.new("", false)
      end
    end

    out, _err = capture_io do
      assert Kyb::Check.assert_java
    end
    assert_match(/✅ Java 21/, out)
  end

  def test_assert_java_install_fails
    Kyb::Check.define_singleton_method(:capture_cmd) do |cmd|
      case cmd
      when 'java -version 2>&1'
        CmdResult.new("java: command not found\n", false)
      when /\Amise install java/
        CmdResult.new("install failed\n", false)
      else
        CmdResult.new(`#{cmd}`, $?.success?)
      end
    end

    out, _err = capture_io do
      refute Kyb::Check.assert_java
    end
    assert_match(/❌/, out)
  end

  # --- assert_pg ---

  def test_assert_pg_already_running
    Kyb::Check.define_singleton_method(:capture_cmd) do |cmd|
      case cmd
      when 'pg_isready -q 2>&1'
        CmdResult.new("", true)
      else
        CmdResult.new(`#{cmd}`, $?.success?)
      end
    end

    out, _err = capture_io do
      assert Kyb::Check.assert_pg
    end
    assert_match(/✅ PostgreSQL is running/, out)
  end

  def test_assert_pg_starts_successfully
    pg_count = 0
    Kyb::Check.define_singleton_method(:capture_cmd) do |cmd|
      case cmd
      when 'pg_isready -q 2>&1'
        pg_count += 1
        if pg_count == 1
          CmdResult.new("", false)
        else
          CmdResult.new("", true)
        end
      when /\Apg_ctlcluster/
        CmdResult.new("", true)
      else
        CmdResult.new(`#{cmd}`, $?.success?)
      end
    end

    out, _err = capture_io do
      assert Kyb::Check.assert_pg
    end
    assert_match(/✅ PostgreSQL started/, out)
  end

  def test_assert_pg_fails_to_start
    Kyb::Check.define_singleton_method(:capture_cmd) do |cmd|
      case cmd
      when 'pg_isready -q 2>&1'
        CmdResult.new("", false)
      when /\Apg_ctlcluster/
        CmdResult.new("", false)
      else
        CmdResult.new(`#{cmd}`, $?.success?)
      end
    end

    out, _err = capture_io do
      refute Kyb::Check.assert_pg
    end
    assert_match(/❌ PostgreSQL failed to start/, out)
  end

  # --- assert_mise_tool ---

  def test_assert_mise_tool_on_path
    Kyb::Check.define_singleton_method(:capture_cmd) do |cmd|
      case cmd
      when /\Awhich mvn/
        CmdResult.new("/home/dev/.local/share/mise/installs/maven/3.9.9/bin/mvn\n", true)
      else
        CmdResult.new(`#{cmd}`, $?.success?)
      end
    end

    out, _err = capture_io do
      assert Kyb::Check.assert_mise_tool('mvn')
    end
    assert_match(/✅ mvn available/, out)
  end

  def test_assert_mise_tool_after_install
    Kyb::Check.define_singleton_method(:capture_cmd) do |cmd|
      case cmd
      when /\Awhich mvn/
        CmdResult.new("", false)
      when /\Amise install mvn/
        CmdResult.new("", true)
      when /\Amise use -g mvn/
        CmdResult.new("", true)
      when /\Amise x mvn -- mvn --version/
        CmdResult.new("Apache Maven 3.9.9\n", true)
      else
        CmdResult.new(`#{cmd}`, $?.success?)
      end
    end

    out, _err = capture_io do
      assert Kyb::Check.assert_mise_tool('mvn')
    end
    assert_match(/✅ mvn available/, out)
  end

  def test_assert_mise_tool_install_fails
    Kyb::Check.define_singleton_method(:capture_cmd) do |cmd|
      case cmd
      when /\Awhich mvn/
        CmdResult.new("", false)
      when /\Amise install mvn/
        CmdResult.new("install failed\n", false)
      else
        CmdResult.new(`#{cmd}`, $?.success?)
      end
    end

    out, _err = capture_io do
      refute Kyb::Check.assert_mise_tool('mvn')
    end
    assert_match(/❌ mvn not found/, out)
  end

  def test_assert_mise_tool_not_found
    Kyb::Check.define_singleton_method(:capture_cmd) do |cmd|
      case cmd
      when /\Awhich mvn/
        CmdResult.new("", false)
      when /\Amise install mvn/
        CmdResult.new("install failed\n", false)
      else
        CmdResult.new(`#{cmd}`, $?.success?)
      end
    end

    out, _err = capture_io do
      refute Kyb::Check.assert_mise_tool('mvn')
    end
    assert_match(/❌ mvn not found/, out)
  end
end
