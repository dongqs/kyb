# frozen_string_literal: true

require_relative 'test_helper'

class CheckTest < Minitest::Test
  def test_check_ruby
    result = Kyb::Check.check_ruby
    assert result[:ok], "Ruby version check: #{result[:msg]}"
    assert_match(/v3\.\d/, result[:msg])
  end

  def test_check_docker
    result = Kyb::Check.check_docker
    assert result[:ok], "Docker should be available: #{result[:msg]}"
    assert_match(/v\d/, result[:msg])
  end

  def test_check_disk
    result = Kyb::Check.check_disk
    assert result[:ok]
    assert_match(/available/, result[:msg])
  end

  def test_proxy_detect
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

  def test_proxy_env_vars_empty
    assert_nil Kyb::Proxy.env_proxy
  end

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
end
