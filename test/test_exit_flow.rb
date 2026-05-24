require_relative 'test_helper'

class ExitFlowTest < Minitest::Test
  CONTAINER = Kyb::Container.new('test', 'br')

  def with_test_repo
    Dir.mktmpdir do |dir|
      system('git', '-C', dir, 'init', '--initial-branch=master', %i[out err] => File::NULL)
      system('git', '-C', dir, 'config', 'user.email', 'test@test', %i[out err] => File::NULL)
      system('git', '-C', dir, 'config', 'user.name', 'test', %i[out err] => File::NULL)
      File.write("#{dir}/f", 'hello')
      system('git', '-C', dir, 'add', 'f', %i[out err] => File::NULL)
      system('git', '-C', dir, 'commit', '-m', 'init', %i[out err] => File::NULL)
      yield dir
    end
  end

  # --- run_idle_checks ---

  def test_idle_checks_all_pass
    with_test_repo do |repo_path|
      # has-session → false (dead), git diff → true (clean)
      system_stub = ->(*args) {
        if args.include?('has-session')
          false
        else
          true
        end
      }
      Kyb.stub(:in_container?, false) do
        Kyb::ExitFlow.stub(:system, system_stub) do
          Kyb::ExitFlow.stub(:`, ->(cmd) { '' }) do
            Kyb::Config.stub(:project, ->(n) { { name: n, path: repo_path, base_branch: 'master' } }) do
              out, = capture_io do
                result = Kyb::ExitFlow.run_idle_checks(CONTAINER, 'test')
                assert result[:tmux], 'tmux should be dead'
                assert result[:dirty], 'repo should be clean'
                assert result[:remote], 'remote should be pushed'
              end
              assert_match(/✔ tmux.*no active sessions/, out)
              assert_match(/✔ repo.*clean/, out)
              assert_match(/✔ remote.*all pushed/, out)
            end
          end
        end
      end
    end
  end

  def test_idle_checks_tmux_alive
    with_test_repo do |repo_path|
      call_count = 0
      system_stub = ->(*args) {
        call_count += 1
        # First call (has-session) returns true → tmux alive
        # Other calls (git diff, etc.) return true
        call_count == 1
      }
      Kyb.stub(:in_container?, false) do
        Kyb::ExitFlow.stub(:system, system_stub) do
          Kyb::ExitFlow.stub(:`, ->(cmd) { '' }) do
            Kyb::Config.stub(:project, ->(n) { { name: n, path: repo_path, base_branch: 'master' } }) do
              out, = capture_io do
                result = Kyb::ExitFlow.run_idle_checks(CONTAINER, 'test')
                refute result[:tmux], 'tmux should be alive'
              end
              assert_match(/✘ tmux.*session still alive/, out)
            end
          end
        end
      end
    end
  end

  def test_idle_checks_repo_dirty
    with_test_repo do |repo_path|
      call_count = 0
      system_stub = ->(*args) {
        call_count += 1
        # has-session returns false (tmux dead)
        # git diff returns false (dirty)
        call_count == 1 ? false : (call_count == 2 ? false : true)
      }
      Kyb.stub(:in_container?, false) do
        Kyb::ExitFlow.stub(:system, system_stub) do
          Kyb::ExitFlow.stub(:`, ->(cmd) { '' }) do
            Kyb::Config.stub(:project, ->(n) { { name: n, path: repo_path, base_branch: 'master' } }) do
              out, = capture_io do
                result = Kyb::ExitFlow.run_idle_checks(CONTAINER, 'test')
                assert result[:tmux], 'tmux should be dead'
                refute result[:dirty], 'repo should be dirty'
              end
              assert_match(/✘ repo.*uncommitted changes/, out)
            end
          end
        end
      end
    end
  end

  def test_idle_checks_unpushed_commits
    with_test_repo do |repo_path|
      system_stub = ->(*args) {
        if args.first == 'docker' && args.include?('has-session')
          false # tmux dead
        elsif args.first == 'git'
          true  # git diff clean
        else
          true
        end
      }
      Kyb.stub(:in_container?, false) do
        Kyb::ExitFlow.stub(:system, system_stub) do
          Kyb::ExitFlow.stub(:`, ->(cmd) { "unpushed\ncommit\n" }) do
            Kyb::Config.stub(:project, ->(n) { { name: n, path: repo_path, base_branch: 'master' } }) do
              out, = capture_io do
                result = Kyb::ExitFlow.run_idle_checks(CONTAINER, 'test')
                refute result[:remote], 'remote should have unpushed'
              end
              assert_match(/✘ remote.*unpushed commits/, out)
            end
          end
        end
      end
    end
  end

  # --- enter_exit_cleanup ---

  def test_cleanup_all_pass_calls_prompt
    called_prompt = false
    Kyb::ExitFlow.stub(:run_idle_checks, { tmux: true, dirty: true, remote: true }) do
      Kyb::ExitFlow.stub(:collect_extra_warnings, []) do
        Kyb::ExitFlow.stub(:interactive_delete_prompt, ->(*) { called_prompt = true }) do
          capture_io { Kyb::ExitFlow.enter_exit_cleanup(CONTAINER, 'test', 'br') }
          assert called_prompt, 'should call prompt when all checks pass'
        end
      end
    end
  end

  def test_cleanup_check_fails_skips_prompt
    called_prompt = false
    Kyb::ExitFlow.stub(:run_idle_checks, { tmux: false, dirty: true, remote: true }) do
      Kyb::ExitFlow.stub(:collect_extra_warnings, []) do
        Kyb::ExitFlow.stub(:interactive_delete_prompt, ->(*) { called_prompt = true }) do
          out, = capture_io { Kyb::ExitFlow.enter_exit_cleanup(CONTAINER, 'test', 'br') }
          refute called_prompt, 'should skip prompt when check fails'
          assert_match(/Cleanup skipped/, out)
        end
      end
    end
  end

  def test_cleanup_all_pass_shows_warnings
    Kyb::ExitFlow.stub(:run_idle_checks, { tmux: true, dirty: true, remote: true }) do
      Kyb::ExitFlow.stub(:collect_extra_warnings, ['processes: node server.js']) do
        Kyb::ExitFlow.stub(:interactive_delete_prompt, nil) do
          out, = capture_io { Kyb::ExitFlow.enter_exit_cleanup(CONTAINER, 'test', 'br') }
          assert_match(/⚠.*node server\.js/, out)
        end
      end
    end
  end

  # --- collect_extra_warnings ---

  def test_extra_warnings_no_unexpected
    capture3_stub = ->(*args) {
      cmd = args.join(' ')
      if cmd.include?('ps -eo')
        ["bash\nsleep\n", "", nil]
      else
        ["", "", nil]
      end
    }
    Open3.stub(:capture3, capture3_stub) do
      warnings = Kyb::ExitFlow.collect_extra_warnings(CONTAINER)
      assert_empty warnings
    end
  end

  def test_extra_warnings_unexpected_process
    capture3_stub = ->(*args) {
      cmd = args.join(' ')
      if cmd.include?('ps -eo')
        ["bash\nsleep\nnode server.js\n", "", nil]
      else
        ["", "", nil]
      end
    }
    Open3.stub(:capture3, capture3_stub) do
      warnings = Kyb::ExitFlow.collect_extra_warnings(CONTAINER)
      assert_includes warnings.first, 'node server.js'
    end
  end

  def test_extra_warnings_did_children
    capture3_stub = ->(*args) {
      cmd = args.join(' ')
      if cmd.include?('ps -eo')
        ["bash\nsleep\n", "", nil]
      else
        ["did-test-child\n", "", nil]
      end
    }
    Open3.stub(:capture3, capture3_stub) do
      warnings = Kyb::ExitFlow.collect_extra_warnings(CONTAINER)
      did_warning = warnings.find { |w| w.include?('did-test-child') }
      assert did_warning, 'should warn about DID children'
    end
  end

  # --- interactive_delete_prompt ---

  def test_prompt_y_cleans
    cleaned = false
    Kyb::ExitFlow.stub(:perform_cleanup, ->(*) { cleaned = true }) do
      # Simulate user typing 'y'
      IO.stub(:select, [[STDIN]]) do
        STDIN.stub(:gets, "y\n") do
          capture_io { Kyb::ExitFlow.interactive_delete_prompt(CONTAINER, 'test', 'br') }
          assert cleaned, 'should clean when user types y'
        end
      end
    end
  end

  def test_prompt_n_skips
    cleaned = false
    Kyb::ExitFlow.stub(:perform_cleanup, ->(*) { cleaned = true }) do
      IO.stub(:select, [[STDIN]]) do
        STDIN.stub(:gets, "n\n") do
          out, = capture_io { Kyb::ExitFlow.interactive_delete_prompt(CONTAINER, 'test', 'br') }
          refute cleaned, 'should skip when user types n'
          assert_match(/Cleanup skipped/, out)
        end
      end
    end
  end

  def test_prompt_timeout_skips
    cleaned = false
    Kyb::ExitFlow.stub(:perform_cleanup, ->(*) { cleaned = true }) do
      IO.stub(:select, nil) do  # timeout → nil
        out, = capture_io { Kyb::ExitFlow.interactive_delete_prompt(CONTAINER, 'test', 'br') }
        refute cleaned, 'should skip on timeout'
        assert_match(/Cleanup skipped/, out)
      end
    end
  end

  def test_prompt_ctrl_c_skips
    cleaned = false
    Kyb::ExitFlow.stub(:perform_cleanup, ->(*) { cleaned = true }) do
      IO.stub(:select, ->(*) { raise Interrupt }) do
        out, = capture_io { Kyb::ExitFlow.interactive_delete_prompt(CONTAINER, 'test', 'br') }
        refute cleaned, 'should skip on Ctrl-C'
        assert_match(/Cleanup skipped/, out)
      end
    end
  end

  # --- perform_cleanup ---

  def test_perform_cleanup_removes_container
    calls = []
    system_stub = ->(*args) { calls << [:system, *args]; true }

    Kyb::Config.stub(:project, { name: 'test', path: '/tmp/test-repo', base_branch: 'master' }) do
      Kyb::ExitFlow.stub(:system, system_stub) do
        Open3.stub(:capture3, ->(*args) { ["", "", nil] }) do
          Kyb::Docker.stub(:volume_rm, nil) do
            capture_io { Kyb::ExitFlow.perform_cleanup(CONTAINER, 'test', 'br') }
          end
        end
      end
    end

    stop_call = calls.find { |c| c[0] == :system && c[1] == 'docker' && c.include?('stop') }
    rm_call   = calls.find { |c| c[0] == :system && c[1] == 'docker' && c.include?('rm') }

    assert stop_call, 'should stop container'
    assert rm_call, 'should remove container'
  end

  def test_perform_cleanup_cascade_did_children
    calls = []
    system_stub = ->(*args) { calls << args; true }

    Kyb::Config.stub(:project, { name: 'test', path: '/tmp/test-repo', base_branch: 'master' }) do
      Open3.stub(:capture3, ->(*args) { args.join(' ').include?('did_parent') ? ["did-child\n", "", nil] : ["", "", nil] }) do
        Kyb::ExitFlow.stub(:system, system_stub) do
          Kyb::Docker.stub(:volume_rm, nil) do
            capture_io { Kyb::ExitFlow.perform_cleanup(CONTAINER, 'test', 'br') }
          end
        end
      end
    end

    did_rm = calls.find { |c| c.include?('did-child') }
    assert did_rm, 'should remove DID children first'
    assert did_rm.include?('rm'), 'should force-remove DID child'
  end
end
