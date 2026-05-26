# frozen_string_literal: true

require_relative 'test_helper'

class BoundaryTest < Minitest::Test
  # ===== Docker container boundary =====

  def test_inside_docker_container
    assert File.exist?('/.dockerenv'),
           'Not inside a Docker container — expected /.dockerenv'
  end

  def test_docker_cli_available
    assert system('command -v docker >/dev/null 2>&1'),
           'docker CLI not found in PATH'
  end

  # ===== kyb container identity =====

  def test_kyb_entrypoint_present
    assert File.exist?('/usr/local/bin/entrypoint.sh'),
           'kyb entrypoint not found — not a kyb container image'
  end

  def test_kyb_lib_baked_in
    assert File.exist?('/home/dev/.kyb/lib/kyb.rb'),
           'kyb lib not found at /home/dev/.kyb/lib/kyb.rb — not a kyb container'
  end

  def test_kyb_cli_wrapper
    kyb = '/home/dev/.kyb/bin/kyb'
    assert File.exist?(kyb), "kyb CLI not at #{kyb}"
    assert File.executable?(kyb), "kyb CLI at #{kyb} is not executable"
  end

  # ===== Runtime user boundary =====

  def test_dev_user
    assert_equal 'dev', ENV.fetch('USER', `whoami`.strip),
                 'Expected USER=dev — not running as kyb container user'
  end

  def test_dev_home
    assert_equal '/home/dev', Dir.home,
                 'Expected home directory /home/dev'
  end

  # ===== Container lifecycle =====

  def test_cmd_is_sleep_infinity
    skip '/proc/1/cmdline not available (not in a container?)' unless File.exist?('/proc/1/cmdline')
    cmd = File.read('/proc/1/cmdline').tr("\0", ' ').strip
    assert_equal 'sleep infinity', cmd,
                 'Unexpected CMD — expected sleep infinity'
  end
end
