require_relative 'test_helper'

class SandboxTest < Minitest::Test
  PROJECTS = %w[niao tts-server].freeze

  def setup
    Kyb::Config.define_singleton_method(:load) { nil }
    Kyb::Config.define_singleton_method(:project_names) { PROJECTS }

    Kyb::CLI.define_singleton_method(:sandbox_create) do |*args|
      @__sandbox_captured = [:create, args]
    end
    Kyb::CLI.define_singleton_method(:sandbox_rm) do |*args|
      @__sandbox_captured = [:rm, args]
    end
  end

  def teardown
    Kyb::Config.singleton_class.remove_method(:load)
    Kyb::Config.singleton_class.remove_method(:project_names)
    Kyb::CLI.singleton_class.remove_method(:sandbox_create)
    Kyb::CLI.singleton_class.remove_method(:sandbox_rm)
  end

  def dispatch(*argv)
    Kyb::CLI.instance_variable_set(:@__sandbox_captured, nil)
    Kyb::CLI.dispatch(argv)
    Kyb::CLI.instance_variable_get(:@__sandbox_captured)
  end

  # -- dispatch ----------------------------------------------------------

  def test_sandbox_create_project_only
    result = dispatch('sandbox', 'niao')
    assert_equal :create, result[0]
    assert_equal ['niao', 'kyb', nil], result[1]
  end

  def test_sandbox_create_project_branch
    result = dispatch('sandbox', 'niao-water')
    assert_equal :create, result[0]
    assert_equal ['niao', 'water', nil], result[1]
  end

  def test_sandbox_create_with_prompt
    result = dispatch('sandbox', 'niao-water', 'fix the bug')
    assert_equal :create, result[0]
    assert_equal ['niao', 'water', 'fix the bug'], result[1]
  end

  def test_sandbox_create_multi_word_prompt
    result = dispatch('sandbox', 'niao-water', 'fix', 'the', 'login', 'form')
    assert_equal :create, result[0]
    assert_equal ['niao', 'water', 'fix the login form'], result[1]
  end

  def test_sandbox_no_arg_dies
    assert_raises(SystemExit) { dispatch('sandbox') }
  end

  def test_sandbox_rm
    result = dispatch('sandbox', 'rm', 'niao-water')
    assert_equal :rm, result[0]
    assert_equal ['niao', 'water'], result[1]
  end

  def test_sandbox_rm_no_arg_dies
    assert_raises(SystemExit) { dispatch('sandbox', 'rm') }
  end

  def test_sandbox_cd
    out, = capture_io { dispatch('sandbox', 'cd', 'niao-water') }
    assert_match %r{worktrees/niao/kyb-niao-water$}, out.strip
  end

  def test_sandbox_cd_no_arg_dies
    assert_raises(SystemExit) { dispatch('sandbox', 'cd') }
  end

  def test_sandbox_multi_dash_project
    result = dispatch('sandbox', 'tts-server-test')
    assert_equal :create, result[0]
    assert_equal ['tts-server', 'test', nil], result[1]
  end

  # -- paths -------------------------------------------------------------

  def test_sandbox_worktree_path
    path = Kyb::CLI.sandbox_worktree_path('niao', 'water')
    assert_match %r{worktrees/niao/kyb-niao-water$}, path
  end

  def test_sandbox_ports_path
    assert_equal '.kyb-ports', File.basename(Kyb::CLI.sandbox_ports_path('/tmp/test'))
  end

  def test_sandbox_pid_path
    assert_equal '.kyb-pid', File.basename(Kyb::CLI.sandbox_pid_path('/tmp/test'))
  end

  # -- ports -------------------------------------------------------------

  def test_assign_port_single
    ports = Kyb::CLI.sandbox_assign_port([3000])
    assert_equal 1, ports.size
    assert ports.first >= 3000
  end

  def test_assign_port_multiple_unique
    ports = Kyb::CLI.sandbox_assign_port([3000, 3000])
    assert_equal 2, ports.size
    refute_equal ports[0], ports[1]
    assert ports[1] > ports[0]
  end

  def test_port_in_use_detection
    server = TCPServer.new('0.0.0.0', 0)
    port = server.addr[1]
    assert Kyb::CLI.port_in_use?(port)
    server.close
  end

  def test_port_free_detection
    assert_equal false, Kyb::CLI.port_in_use?(29_999)
  end

  # -- process -----------------------------------------------------------

  def test_process_alive_current_process
    assert Kyb::CLI.process_alive?(Process.pid)
  end

  def test_process_alive_dead_pid
    refute Kyb::CLI.process_alive?(0)
    refute Kyb::CLI.process_alive?(-1)
    refute Kyb::CLI.process_alive?(nil)
  end

  # -- ps ---------------------------------------------------------------

  def test_sandbox_ps_empty
    Dir.mktmpdir do |dir|
      old = Kyb::CLI::SANDBOX_WORKTREE_BASE
      Kyb::CLI.send(:remove_const, :SANDBOX_WORKTREE_BASE)
      Kyb::CLI.const_set(:SANDBOX_WORKTREE_BASE, File.join(dir, 'nonexistent'))
      assert_output("(no sandboxes)\n") do
        Kyb::CLI.sandbox_ps
      end
    ensure
      Kyb::CLI.send(:remove_const, :SANDBOX_WORKTREE_BASE) rescue nil
      Kyb::CLI.const_set(:SANDBOX_WORKTREE_BASE, old)
    end
  end

  # -- settings -----------------------------------------------------------

  def test_write_sandbox_settings_filesystem_allowWrite
    Dir.mktmpdir do |dir|
      Kyb::CLI.write_sandbox_settings(dir, 'test-proj')
      settings = JSON.parse(File.read(File.join(dir, '.claude', 'settings.json')))
      assert_equal [dir], settings.dig('sandbox', 'filesystem', 'allowWrite')
      assert settings.dig('sandbox', 'enableWeakerNetworkIsolation')
    end
  end

  # -- claude md ----------------------------------------------------------

  def test_write_sandbox_claude_md_node_modules
    Dir.mktmpdir do |dir|
      proj = { mounts_rw: nil, mounts_ro: nil }
      Kyb::CLI.write_sandbox_claude_md(dir, 'test-proj', 'feature', '/repo/test-proj', [], proj)
      content = File.read(File.join(dir, '.kyb-claude.md'))
      assert_match 'read-only from `/repo/test-proj/node_modules`', content
      assert_match 'Run `npm install` in the original repo', content
    end
  end

  def test_sandbox_ps_with_sandboxes
    Dir.mktmpdir do |dir|
      old = Kyb::CLI::SANDBOX_WORKTREE_BASE
      Kyb::CLI.send(:remove_const, :SANDBOX_WORKTREE_BASE)
      Kyb::CLI.const_set(:SANDBOX_WORKTREE_BASE, dir)
      wt = File.join(dir, 'niao', 'kyb-niao-water')
      FileUtils.mkdir_p(wt)
      File.write(File.join(wt, '.kyb-pid'), Process.pid.to_s)
      File.write(File.join(wt, '.kyb-ports'), '3000')

      out, = capture_io { Kyb::CLI.sandbox_ps }
      assert_match 'kyb-niao-water', out
      assert_match 'running', out
      assert_match '3000', out
    ensure
      Kyb::CLI.send(:remove_const, :SANDBOX_WORKTREE_BASE) rescue nil
      Kyb::CLI.const_set(:SANDBOX_WORKTREE_BASE, old)
    end
  end
end
