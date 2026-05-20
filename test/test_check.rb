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

  def test_detect_build_proxy
    proxy = Kyb::Check.detect_build_proxy
    refute_nil proxy, 'Dockerfile should have ALL_PROXY'
    assert_match(%r{socks5://}, proxy)
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
