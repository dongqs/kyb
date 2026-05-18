require_relative 'test_helper'

class SessionTest < Minitest::Test
  def setup
    Kyb::CLI.define_singleton_method(:session_wrap) do |cli, cli_args|
      @__captured = [:session_wrap, cli, cli_args]
    end
  end

  def teardown
    Kyb::CLI.singleton_class.remove_method(:session_wrap)
  end

  def dispatch(*argv)
    Kyb::CLI.instance_variable_set(:@__captured, nil)
    Kyb::CLI.dispatch(argv)
    Kyb::CLI.instance_variable_get(:@__captured)
  end

  # --- dispatch ---

  def test_session_wrap_dispatch
    Kyb::Config.stub(:load, nil) do
      cmd, cli, cli_args = dispatch('session', 'wrap', 'claude', 'read doc')
      assert_equal :session_wrap, cmd
      assert_equal 'claude', cli
      assert_equal ['read doc'], cli_args
    end
  end

  def test_session_wrap_dispatch_kimi
    Kyb::Config.stub(:load, nil) do
      cmd, cli, cli_args = dispatch('session', 'wrap', 'kimi', '-p', 'hello')
      assert_equal :session_wrap, cmd
      assert_equal 'kimi', cli
      assert_equal ['-p', 'hello'], cli_args
    end
  end

  def test_session_wrap_no_args_dies
    assert_raises(SystemExit) { Kyb::Config.stub(:load, nil) { dispatch('session') } }
  end

  def test_session_wrap_no_command_dies
    assert_raises(SystemExit) { Kyb::Config.stub(:load, nil) { dispatch('session', 'wrap') } }
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
