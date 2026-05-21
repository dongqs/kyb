require_relative 'test_helper'

class CLITest < Minitest::Test
  PROJECTS = %w[niao tts-server tts].freeze

  def setup
    Kyb::Config.define_singleton_method(:load) { nil }
    Kyb::Config.define_singleton_method(:project_names) { PROJECTS }

    # Methods without keyword args
    %i[stop start rm].each do |m|
      Kyb::CLI.define_singleton_method(m) do |*args|
        @__captured = [m, args]
      end
    end

    # Methods with keyword args — explicit signatures keep capture clean
    Kyb::CLI.define_singleton_method(:create) do |project, branch, port_overrides = nil, **|
      @__captured = [:create, [project, branch, port_overrides]]
    end

    Kyb::CLI.define_singleton_method(:enter) do |project, branch, **|
      @__captured = [:enter, [project, branch]]
    end

    # DID subcommands
    Kyb::CLI.define_singleton_method(:did_create) do |args|
      @__captured = [:did_create, args]
    end
    Kyb::CLI.define_singleton_method(:did_rm) do |args|
      @__captured = [:did_rm, args]
    end
    Kyb::CLI.define_singleton_method(:did_ps) do |show_all: false|
      @__captured = [:did_ps, show_all]
    end
  end

  def teardown
    Kyb::Config.singleton_class.remove_method(:load)
    Kyb::Config.singleton_class.remove_method(:project_names)

    %i[create enter stop start rm].each do |m|
      Kyb::CLI.singleton_class.remove_method(m)
    end
    %i[did_create did_rm did_ps].each do |m|
      Kyb::CLI.singleton_class.remove_method(m)
    end
  end

  def dispatch(*argv)
    Kyb::CLI.instance_variable_set(:@__captured, nil)
    Kyb::CLI.dispatch(argv)
    Kyb::CLI.instance_variable_get(:@__captured)
  end

  # --- create ---

  def test_create_project_only
    cmd, args = dispatch('create', 'niao')
    assert_equal :create, cmd
    assert_equal ['niao', 'kyb', nil], args
  end

  def test_create_project_branch
    cmd, args = dispatch('create', 'niao-water')
    assert_equal :create, cmd
    assert_equal ['niao', 'water', nil], args
  end

  def test_create_with_ports_flag
    cmd, args = dispatch('create', 'niao', '--ports', '3000:3001')
    assert_equal :create, cmd
    assert_equal ['niao', 'kyb', '3000:3001'], args
  end

  def test_create_project_branch_and_ports
    cmd, args = dispatch('create', 'niao-water', '--ports', '3000:3001')
    assert_equal :create, cmd
    assert_equal ['niao', 'water', '3000:3001'], args
  end

  def test_create_no_arg_dies
    assert_raises(SystemExit) { dispatch('create') }
  end

  # --- enter ---

  def test_enter_project_only
    cmd, args = dispatch('enter', 'niao')
    assert_equal :enter, cmd
    assert_equal ['niao', 'kyb'], args[0..1]
  end

  def test_enter_project_branch
    cmd, args = dispatch('enter', 'niao-water')
    assert_equal :enter, cmd
    assert_equal ['niao', 'water'], args[0..1]
  end

  def test_enter_no_arg_dies
    assert_raises(SystemExit) { dispatch('enter') }
  end

  # --- stop / start / rm ---

  def test_stop_project_branch
    cmd, args = dispatch('stop', 'niao-water')
    assert_equal :stop, cmd
    assert_equal ['niao', 'water'], args
  end

  def test_start_project_branch
    cmd, args = dispatch('start', 'niao-water')
    assert_equal :start, cmd
    assert_equal ['niao', 'water'], args
  end

  def test_rm_project_branch
    cmd, args = dispatch('rm', 'niao-water')
    assert_equal :rm, cmd
    assert_equal ['niao', 'water'], args
  end

  # --- multi-dash project ---

  def test_multi_dash_project_create
    cmd, args = dispatch('create', 'tts-server-test')
    assert_equal :create, cmd
    assert_equal ['tts-server', 'test', nil], args
  end

  def test_multi_dash_project_create_default_branch
    cmd, args = dispatch('create', 'tts-server')
    assert_equal :create, cmd
    assert_equal ['tts-server', 'kyb', nil], args
  end

  # --- --profile ---

  def test_profile_flag_consumed
    # --profile before command should be consumed, dispatch unchanged
    cmd, args = dispatch('--profile', 'create', 'niao')
    assert_equal :create, cmd
    assert_equal ['niao', 'kyb', nil], args
  end

  def test_profile_with_enter
    cmd, args = dispatch('--profile', 'enter', 'niao-water')
    assert_equal :enter, cmd
    assert_equal ['niao', 'water'], args
  end

  def test_profile_with_stop
    cmd, args = dispatch('--profile', 'stop', 'niao-water')
    assert_equal :stop, cmd
    assert_equal ['niao', 'water'], args
  end

  # --- TimestampedOutput ---

  def test_timestamped_puts
    out, = capture_io do
      io = Kyb::TimestampedOutput.new($stdout)
      io.puts 'hello'
    end
    assert_match(/^\[\d{2}:\d{2}:\d{2}\] hello\n$/, out)
  end

  def test_timestamped_puts_blank_line
    out, = capture_io do
      io = Kyb::TimestampedOutput.new($stdout)
      io.puts
    end
    assert_equal "\n", out
  end

  def test_timestamped_puts_multiple_args
    out, = capture_io do
      io = Kyb::TimestampedOutput.new($stdout)
      io.puts 'a', 'b'
    end
    lines = out.split("\n")
    assert_equal 2, lines.size
    assert_match(/^\[\d{2}:\d{2}:\d{2}\] a$/, lines[0])
    assert_match(/^\[\d{2}:\d{2}:\d{2}\] b$/, lines[1])
  end

  def test_timestamped_print
    out, = capture_io do
      io = Kyb::TimestampedOutput.new($stdout)
      io.print 'working'
    end
    assert_match(/^\[\d{2}:\d{2}:\d{2}\] working$/, out)
  end

  def test_timestamped_printf
    out, = capture_io do
      io = Kyb::TimestampedOutput.new($stdout)
      io.printf "%-10s %s\n", 'A', 'B'
    end
    assert_match(/^\[\d{2}:\d{2}:\d{2}\] A          B\n$/, out)
  end

  def test_enable_profile_timestamps_puts
    original = $stdout
    begin
      out, = capture_io do
        Kyb.enable_profile
        puts 'test'
      end
      assert_match(/^\[\d{2}:\d{2}:\d{2}\] test\n$/, out)
    ensure
      $stdout = original
    end
  end

  # --- did ---

  def test_did_create
    cmd, args = dispatch('did', 'create', 'mybox')
    assert_equal :did_create, cmd
    assert_equal ['mybox'], args
  end

  def test_did_rm
    cmd, args = dispatch('did', 'rm', 'mybox')
    assert_equal :did_rm, cmd
    assert_equal ['mybox'], args
  end

  def test_did_ps
    cmd, show_all = dispatch('did', 'ps')
    assert_equal :did_ps, cmd
    refute show_all
  end

  def test_did_ls
    cmd, show_all = dispatch('did', 'ls')
    assert_equal :did_ps, cmd
    refute show_all
  end

  def test_did_ps_all
    cmd, show_all = dispatch('did', 'ps', '--all')
    assert_equal :did_ps, cmd
    assert show_all
  end

  def test_did_ps_a
    cmd, show_all = dispatch('did', 'ps', '-a')
    assert_equal :did_ps, cmd
    assert show_all
  end

  def test_did_ls_all
    cmd, show_all = dispatch('did', 'ls', '--all')
    assert_equal :did_ps, cmd
    assert show_all
  end

  def test_did_no_args_shows_help
    out, = capture_io { dispatch('did') }
    assert_match(/kyb did/, out)
  end

  def test_did_create_no_name_dies
    assert_raises(SystemExit) { capture_io { dispatch('did', 'create') } }
  end

  def test_did_rm_no_name_dies
    assert_raises(SystemExit) { capture_io { dispatch('did', 'rm') } }
  end

  # --- assert ---

  def test_assert_java_dispatch
    captured_version = nil
    Kyb::Check.define_singleton_method(:assert_java) do |expected_version:|
      captured_version = expected_version
      true
    end
    dispatch('assert', 'java', '17')
    assert_equal '17', captured_version
  ensure
    Kyb::Check.singleton_class.remove_method(:assert_java)
  end

  def test_assert_java_default_version
    captured_version = nil
    Kyb::Check.define_singleton_method(:assert_java) do |expected_version:|
      captured_version = expected_version
      true
    end
    dispatch('assert', 'java')
    assert_equal '21', captured_version
  ensure
    Kyb::Check.singleton_class.remove_method(:assert_java)
  end

  def test_assert_pg_dispatch
    called = false
    Kyb::Check.define_singleton_method(:assert_pg) do
      called = true
      true
    end
    dispatch('assert', 'pg')
    assert called
  ensure
    Kyb::Check.singleton_class.remove_method(:assert_pg)
  end

  def test_assert_mise_dispatch
    captured_tool = nil
    Kyb::Check.define_singleton_method(:assert_mise_tool) do |tool|
      captured_tool = tool
      true
    end
    dispatch('assert', 'mise', 'mvn')
    assert_equal 'mvn', captured_tool
  ensure
    Kyb::Check.singleton_class.remove_method(:assert_mise_tool)
  end

  def test_assert_unknown_type_dies
    assert_raises(SystemExit) { capture_io { dispatch('assert', 'unknown') } }
  end

  def test_assert_mise_no_tool_dies
    assert_raises(SystemExit) { capture_io { dispatch('assert', 'mise') } }
  end

  def test_assert_help
    out, _ = capture_io { dispatch('assert', 'help') }
    assert_match(/kyb assert/, out)
  end

  # --- version ---

  def test_version
    assert_equal '0.10.0', Kyb::VERSION
  end

  # --- notify ---

  def test_notify_dispatch_done
    Kyb::CLI.define_singleton_method(:notify) do |level, message|
      @__captured = [:notify, level, message]
    end
    cmd, level, msg = dispatch('notify', 'done', 'hello world')
    assert_equal :notify, cmd
    assert_equal 'done', level
    assert_equal 'hello world', msg
  ensure
    Kyb::CLI.singleton_class.remove_method(:notify)
  end

  def test_notify_dispatch_blocked
    Kyb::CLI.define_singleton_method(:notify) do |level, message|
      @__captured = [:notify, level, message]
    end
    cmd, level, msg = dispatch('notify', 'blocked', 'server 502')
    assert_equal :notify, cmd
    assert_equal 'blocked', level
    assert_equal 'server 502', msg
  ensure
    Kyb::CLI.singleton_class.remove_method(:notify)
  end

  def test_notify_dispatch_urgent
    Kyb::CLI.define_singleton_method(:notify) do |level, message|
      @__captured = [:notify, level, message]
    end
    cmd, level, msg = dispatch('notify', 'urgent', 'push prod')
    assert_equal :notify, cmd
    assert_equal 'urgent', level
    assert_equal 'push prod', msg
  ensure
    Kyb::CLI.singleton_class.remove_method(:notify)
  end

  def test_notify_no_args_dies
    assert_raises(SystemExit) { dispatch('notify') }
  end

  def test_notify_one_arg_dies
    assert_raises(SystemExit) { dispatch('notify', 'done') }
  end

  def test_notify_invalid_level_dies
    assert_raises(SystemExit) { dispatch('notify', 'invalid', 'msg') }
  end

  # -- fix_did_swift_path ----------------------------------------------------

  def test_fix_did_swift_path_adds_path_when_swift_exists
    calls = []
    stubbed = ->(*args) { calls << args; true }

    Kyb::CLI.stub(:system, stubbed) do
      Kyb::CLI.fix_did_swift_path('did-niao')
    end

    sed_call = calls.find { |a| a.include?('sed') }
    assert sed_call, 'expected sed call to fix PATH'
    assert_includes sed_call.join(' '), '/home/dev/.local/swift/usr/bin'
  end

  def test_fix_did_swift_path_skips_when_no_swift
    calls = []
    stubbed = ->(*args) { calls << args; false }

    Kyb::CLI.stub(:system, stubbed) do
      Kyb::CLI.fix_did_swift_path('did-niao')
    end

    sed_call = calls.find { |a| a.include?('sed') }
    assert_nil sed_call, 'no sed call expected when swift missing'
    assert_equal 1, calls.length
    assert_includes calls.first, 'test'
  end
end
