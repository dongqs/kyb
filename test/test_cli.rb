require_relative 'test_helper'

class CLITest < Minitest::Test
  # Override before all tests — after load, define_module_function ensures
  # singleton methods are on Kyb::CLI. We replace them with spares.
  def self.mock!(name)
    Kyb::CLI.define_singleton_method(name) do |*args|
      @__captured = [name, args]
    end
  end

  %i[create enter stop start rm].each { |m| mock!(m) }

  def dispatch(*argv)
    Kyb::CLI.instance_variable_set(:@__captured, nil)
    Kyb::CLI.dispatch(argv)
    Kyb::CLI.instance_variable_get(:@__captured)
  end

  # --- create ---

  def test_create_name_only
    cmd, args = dispatch('create', 'niao')
    assert_equal :create, cmd
    assert_equal ['niao', nil, nil], args
  end

  def test_create_name_and_suffix
    cmd, args = dispatch('create', 'niao', 'water')
    assert_equal :create, cmd
    assert_equal ['niao', 'water', nil], args
  end

  def test_create_with_ports_flag
    cmd, args = dispatch('create', 'niao', '--ports', '3000:3001')
    assert_equal :create, cmd
    assert_equal ['niao', nil, '3000:3001'], args
  end

  def test_create_name_suffix_and_ports
    cmd, args = dispatch('create', 'niao', 'water', '--ports', '3000:3001')
    assert_equal :create, cmd
    assert_equal ['niao', 'water', '3000:3001'], args
  end

  def test_create_no_name_dies
    assert_raises(SystemExit) { dispatch('create') }
  end

  # --- enter ---

  def test_enter_name_only
    cmd, args = dispatch('enter', 'niao')
    assert_equal :enter, cmd
    assert_equal ['niao', nil], args
  end

  def test_enter_name_and_suffix
    cmd, args = dispatch('enter', 'niao', 'water')
    assert_equal :enter, cmd
    assert_equal ['niao', 'water'], args
  end

  def test_enter_no_name_dies
    assert_raises(SystemExit) { dispatch('enter') }
  end

  # --- stop / start / rm ---

  def test_stop_passes_suffix
    cmd, args = dispatch('stop', 'niao', 'water')
    assert_equal :stop, cmd
    assert_equal ['niao', 'water'], args
  end

  def test_start_passes_suffix
    cmd, args = dispatch('start', 'niao', 'water')
    assert_equal :start, cmd
    assert_equal ['niao', 'water'], args
  end

  def test_rm_passes_suffix
    cmd, args = dispatch('rm', 'niao', 'water')
    assert_equal :rm, cmd
    assert_equal ['niao', 'water'], args
  end
end
