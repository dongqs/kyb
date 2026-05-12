require_relative 'test_helper'

class CLITest < Minitest::Test
  PROJECTS = %w[niao tts-server tts].freeze

  def setup
    Kyb::Config.define_singleton_method(:load) { nil }
    Kyb::Config.define_singleton_method(:project_names) { PROJECTS }

    %i[create enter stop start rm].each do |m|
      Kyb::CLI.define_singleton_method(m) do |*args|
        @__captured = [m, args]
      end
    end
  end

  def teardown
    Kyb::Config.singleton_class.remove_method(:load)
    Kyb::Config.singleton_class.remove_method(:project_names)

    %i[create enter stop start rm].each do |m|
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
    assert_equal ['niao', 'kyb'], args
  end

  def test_enter_project_branch
    cmd, args = dispatch('enter', 'niao-water')
    assert_equal :enter, cmd
    assert_equal ['niao', 'water'], args
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
end
