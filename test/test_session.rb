require_relative 'test_helper'

class SessionTest < Minitest::Test
  # --- dispatch ---

  def test_session_wrap_dispatch
    captured = nil
    Kyb::CLI.stub(:session_wrap, ->(cli, cli_args) { captured = [:session_wrap, cli, cli_args] }) do
      Kyb::Config.stub(:load, nil) do
        Kyb::CLI.dispatch(['session', 'wrap', 'claude', 'read doc'])
      end
    end
    cmd, cli, cli_args = captured
    assert_equal :session_wrap, cmd
    assert_equal 'claude', cli
    assert_equal ['read doc'], cli_args
  end

  def test_session_wrap_dispatch_kimi
    captured = nil
    Kyb::CLI.stub(:session_wrap, ->(cli, cli_args) { captured = [:session_wrap, cli, cli_args] }) do
      Kyb::Config.stub(:load, nil) do
        Kyb::CLI.dispatch(['session', 'wrap', 'kimi', '-p', 'hello'])
      end
    end
    cmd, cli, cli_args = captured
    assert_equal :session_wrap, cmd
    assert_equal 'kimi', cli
    assert_equal ['-p', 'hello'], cli_args
  end

  def test_session_wrap_no_args_dies
    assert_raises(SystemExit) { Kyb::Config.stub(:load, nil) { Kyb::CLI.dispatch(['session']) } }
  end

  def test_session_wrap_no_command_dies
    assert_raises(SystemExit) { Kyb::Config.stub(:load, nil) { Kyb::CLI.dispatch(['session', 'wrap']) } }
  end

  # --- formatting ---

  def test_format_duration_seconds
    assert_equal '5s', Kyb::CLI.format_duration(5)
  end

  def test_format_duration_minutes
    assert_equal '2m 3s', Kyb::CLI.format_duration(123)
  end

  def test_format_duration_hours
    assert_equal '1h 0m 5s', Kyb::CLI.format_duration(3605)
  end

  def test_format_duration_zero
    assert_equal '0s', Kyb::CLI.format_duration(0)
  end

  def test_format_duration_rounding
    assert_equal '1s', Kyb::CLI.format_duration(1.7)
  end

  def test_session_stats_format
    stats = Kyb::CLI.format_session_stats(3665, 'claude')
    assert_includes stats, '1h 1m 5s'
    assert_includes stats, 'claude'
  end

  def test_session_stats_has_separator
    stats = Kyb::CLI.format_session_stats(60, 'bash')
    assert_includes stats, '━━━'
    assert_includes stats, '────────────────────'
  end
end
