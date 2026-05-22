# frozen_string_literal: true

require_relative 'test_helper'

class InfraTest < Minitest::Test
  BOSS = Kyb::CLI::BOSS_NAME
  SING_BOX = Kyb::CLI::SING_BOX
  BT = :"`"

  # ===== HELP =====

  def test_infra_help
    out, = capture_io { Kyb::CLI.infra_help }
    assert_match(/Usage: kyb infra/, out)
    assert_match(/up/, out)
    assert_match(/down/, out)
    assert_match(/enter/, out)
    assert_match(/ps/, out)
    assert_match(/logs/, out)
    assert_match(/restart/, out)
  end

  def test_infra_no_args_shows_help
    out, = capture_io { Kyb::CLI.infra([]) }
    assert_match(/Usage: kyb infra/, out)
  end

  def test_infra_unknown_command_shows_help
    out, = capture_io { Kyb::CLI.infra(['bogus']) }
    assert_match(/Usage: kyb infra/, out)
  end

  # ===== DISPATCH ROUTING =====

  def test_infra_up_dispatch
    captured = false
    orig = Kyb::CLI.method(:infra_up) rescue nil
    Kyb::CLI.define_singleton_method(:infra_up) { captured = true }
    Kyb::CLI.infra(['up'])
    assert captured
  ensure
    Kyb::CLI.define_singleton_method(:infra_up, orig) if orig
  end

  def test_infra_create_dispatch
    captured = false
    orig = Kyb::CLI.method(:infra_up) rescue nil
    Kyb::CLI.define_singleton_method(:infra_up) { captured = true }
    Kyb::CLI.infra(['create'])
    assert captured
  ensure
    Kyb::CLI.define_singleton_method(:infra_up, orig) if orig
  end

  def test_infra_down_dispatch
    captured = false
    orig = Kyb::CLI.method(:infra_down) rescue nil
    Kyb::CLI.define_singleton_method(:infra_down) { captured = true }
    Kyb::CLI.infra(['down'])
    assert captured
  ensure
    Kyb::CLI.define_singleton_method(:infra_down, orig) if orig
  end

  def test_infra_rm_dispatch
    captured = false
    orig = Kyb::CLI.method(:infra_down) rescue nil
    Kyb::CLI.define_singleton_method(:infra_down) { captured = true }
    Kyb::CLI.infra(['rm'])
    assert captured
  ensure
    Kyb::CLI.define_singleton_method(:infra_down, orig) if orig
  end

  def test_infra_ps_dispatch
    captured = false
    orig = Kyb::CLI.method(:infra_ps) rescue nil
    Kyb::CLI.define_singleton_method(:infra_ps) { captured = true }
    Kyb::CLI.infra(['ps'])
    assert captured
  ensure
    Kyb::CLI.define_singleton_method(:infra_ps, orig) if orig
  end

  def test_infra_ls_dispatch
    captured = false
    orig = Kyb::CLI.method(:infra_ps) rescue nil
    Kyb::CLI.define_singleton_method(:infra_ps) { captured = true }
    Kyb::CLI.infra(['ls'])
    assert captured
  ensure
    Kyb::CLI.define_singleton_method(:infra_ps, orig) if orig
  end

  def test_infra_enter_dispatch
    captured = false
    orig = Kyb::CLI.method(:infra_enter) rescue nil
    Kyb::CLI.define_singleton_method(:infra_enter) { captured = true }
    Kyb::CLI.infra(['enter'])
    assert captured
  ensure
    Kyb::CLI.define_singleton_method(:infra_enter, orig) if orig
  end

  def test_infra_ssh_dispatch
    captured = false
    orig = Kyb::CLI.method(:infra_enter) rescue nil
    Kyb::CLI.define_singleton_method(:infra_enter) { captured = true }
    Kyb::CLI.infra(['ssh'])
    assert captured
  ensure
    Kyb::CLI.define_singleton_method(:infra_enter, orig) if orig
  end

  def test_infra_logs_dispatch
    captured = nil
    orig = Kyb::CLI.method(:infra_logs) rescue nil
    Kyb::CLI.define_singleton_method(:infra_logs) { |*a| captured = a }
    Kyb::CLI.infra(['logs'])
    assert_equal [nil], captured
  ensure
    Kyb::CLI.define_singleton_method(:infra_logs, orig) if orig
  end

  def test_infra_logs_with_arg_dispatch
    captured = nil
    orig = Kyb::CLI.method(:infra_logs) rescue nil
    Kyb::CLI.define_singleton_method(:infra_logs) { |*a| captured = a }
    Kyb::CLI.infra(['logs', 'my-box'])
    assert_equal ['my-box'], captured
  ensure
    Kyb::CLI.define_singleton_method(:infra_logs, orig) if orig
  end

  def test_infra_restart_dispatch
    captured = nil
    orig = Kyb::CLI.method(:infra_restart) rescue nil
    Kyb::CLI.define_singleton_method(:infra_restart) { |*a| captured = a }
    Kyb::CLI.infra(['restart'])
    assert_equal [nil], captured
  ensure
    Kyb::CLI.define_singleton_method(:infra_restart, orig) if orig
  end

  def test_infra_restart_with_arg_dispatch
    captured = nil
    orig = Kyb::CLI.method(:infra_restart) rescue nil
    Kyb::CLI.define_singleton_method(:infra_restart) { |*a| captured = a }
    Kyb::CLI.infra(['restart', 'boss'])
    assert_equal ['boss'], captured
  ensure
    Kyb::CLI.define_singleton_method(:infra_restart, orig) if orig
  end

  # ===== infra_ps =====

  def test_infra_ps
    bt = ->(cmd) { "kyb-infra-boss\tUp 2 hours\t0.0.0.0:80->80/tcp" }
    out, = capture_io {
      Kyb::CLI.stub(BT, bt) { Kyb::CLI.infra_ps }
    }
    assert_match(/kyb-infra-boss/, out)
    assert_match(/CONTAINER/, out)
    assert_match(/Up 2 hours/, out)
  end

  def test_infra_ps_empty
    bt = ->(_cmd) { "" }
    out, = capture_io {
      Kyb::CLI.stub(BT, bt) { Kyb::CLI.infra_ps }
    }
    assert_match(/No infra containers/, out)
  end

  # ===== infra_logs =====

  def test_infra_logs_default
    calls = []
    sys = ->(*args, **_) { calls << args; true }
    Kyb::CLI.stub(:system, sys) do
      capture_io { Kyb::CLI.infra_logs(nil) }
    end
    cmd = calls.first
    assert_equal 'docker', cmd[0]
    assert_equal 'logs', cmd[1]
    assert_equal '--tail', cmd[2]
    assert_equal '30', cmd[3]
    assert_equal SING_BOX, cmd[4]
  end

  def test_infra_logs_boss
    calls = []
    sys = ->(*args, **_) { calls << args; true }
    Kyb::CLI.stub(:system, sys) do
      capture_io { Kyb::CLI.infra_logs(BOSS) }
    end
    assert_equal BOSS, calls.first.last
  end

  # ===== infra_restart =====

  def test_infra_restart_default
    calls = []
    sys = ->(*args, **_) { calls << args; true }
    out, = capture_io {
      Kyb::CLI.stub(:system, sys) { Kyb::CLI.infra_restart(nil) }
    }
    assert_match(/restarting/, out)
    assert_equal 'docker', calls.first[0]
    assert_equal 'restart', calls.first[1]
    assert_equal SING_BOX, calls.first[2]
  end

  def test_infra_restart_boss
    calls = []
    sys = ->(*args, **_) { calls << args; true }
    out, = capture_io {
      Kyb::CLI.stub(:system, sys) { Kyb::CLI.infra_restart(BOSS) }
    }
    assert_match(/restarting/, out)
    assert_equal BOSS, calls.first.last
  end

  # ===== infra_up =====

  def test_infra_up_when_already_running
    calls = []
    bt = ->(cmd) {
      case cmd
      when /docker ps -a/ then BOSS
      when /docker inspect/ then 'running'
      else ''
      end
    }
    sys = ->(*args, **_) { calls << args; true }
    out, = capture_io {
      Kyb::CLI.stub(BT, bt) {
        Kyb::CLI.stub(:system, sys) { Kyb::CLI.infra_up }
      }
    }
    assert_match(/already exists/, out)
    assert_match(/Status: running/, out)
    assert_empty calls, "expected no system calls when already running"
  end

  def test_infra_up_exists_but_stopped
    calls = []
    bt = ->(cmd) {
      case cmd
      when /docker ps -a/ then BOSS
      when /docker inspect/ then 'exited'
      else ''
      end
    }
    sys = ->(*args, **_) { calls << args; true }
    out, = capture_io {
      Kyb::CLI.stub(BT, bt) {
        Kyb::CLI.stub(:system, sys) { Kyb::CLI.infra_up }
      }
    }
    assert_match(/already exists/, out)
    assert_match(/Status: exited/, out)
    start_call = calls.find { |a| a[0..1] == %w[docker start] }
    assert start_call, "expected docker start, got: #{calls.inspect}"
  end

  def test_infra_up_creates_new_container
    bt = ->(_cmd) { '' }
    calls = []
    sys = ->(*args, **_) { calls << args; true }

    real_exist = File.method(:exist?)
    real_dir   = File.method(:directory?)

    exist_stub = ->(p) {
      case p
      when '/var/run/tailscaled.socket' then false
      when /settings\.json$/ then false
      else real_exist.call(p)
      end
    }

    dir_stub = ->(p) {
      case p
      when /\.ssh$/ then false
      when /\.config\/kyb$/ then false
      when /skills$/ then false
      when /sing-box$/ then false
      when /kyb-infra-boss$/ then true  # pretend clone exists so chdir works
      else real_dir.call(p)
      end
    }

    out, = capture_io {
      File.stub(:exist?, exist_stub) {
        File.stub(:directory?, dir_stub) {
          Kyb::CLI.stub(BT, bt) {
            Kyb::CLI.stub(:system, sys) { Kyb::CLI.infra_up }
          }
        }
      }
    }

    # Verify network create
    net_create = calls.find { |a| a[0..2] == %w[docker network create] }
    assert net_create, "expected docker network create, got: #{calls.inspect}"
    assert_equal 'kyb-net', net_create[3]

    # Verify sing-box network connect
    net_conn = calls.find { |a| a[0..2] == %w[docker network connect] }
    assert net_conn, "expected docker network connect, got: #{calls.inspect}"
    assert_equal 'kyb-net', net_conn[3]
    assert_equal SING_BOX, net_conn[4]

    # Verify volumes created
    vol_names = calls.select { |a| a[0..2] == %w[docker volume create] }.map { |a| a[3] }
    assert_includes vol_names, 'kyb-gradle-cache'
    assert_includes vol_names, 'kyb-maven-cache'
    assert_includes vol_names, 'kyb-mise-cache'
    assert_includes vol_names, 'kyb-pip-cache'

    # Verify docker run
    run_call = calls.find { |a| a[0..1] == %w[docker run] }
    assert run_call, "expected docker run, got: #{calls.inspect}"

    # --name
    assert run_call.include?('--name'), 'expected --name flag'
    name_idx = run_call.index('--name')
    assert_equal BOSS, run_call[name_idx + 1]

    # --network
    assert run_call.include?('--network'), 'expected --network flag'
    net_idx = run_call.index('--network')
    assert_equal 'kyb-net', run_call[net_idx + 1]

    # --restart
    assert run_call.include?('--restart'), 'expected --restart flag'
    rst_idx = run_call.index('--restart')
    assert_equal 'unless-stopped', run_call[rst_idx + 1]

    # ALL_PROXY env
    assert run_call.any? { |e| e.include?('ALL_PROXY=socks5://kyb-infra-sing-box:2080') },
           'expected ALL_PROXY env var'

    # docker socket mount
    assert run_call.any? { |e| e.include?('/var/run/docker.sock:/var/run/docker.sock') },
           'expected docker.sock mount'

    # kyb repo mount (clone target at /home/dev/projects/kyb)
    assert run_call.any? { |e| e.include?('/home/dev/projects/kyb') },
           'expected kyb repo rw mount'

    # --hostname
    assert run_call.include?('--hostname'), 'expected --hostname flag'
    hn_idx = run_call.index('--hostname')
    assert_equal BOSS, run_call[hn_idx + 1]

    # HOST_UID / HOST_GID env
    assert run_call.any? { |e| e.start_with?('HOST_UID=') }, 'expected HOST_UID env'
    assert run_call.any? { |e| e.start_with?('HOST_GID=') }, 'expected HOST_GID env'

    # Volume mounts
    assert run_call.include?('kyb-gradle-cache:/home/dev/.gradle')
    assert run_call.include?('kyb-maven-cache:/home/dev/.m2/repository')
    assert run_call.include?('kyb-mise-cache:/home/dev/.local/share/mise/downloads')
    assert run_call.include?('kyb-pip-cache:/home/dev/.cache/pip')

    assert_match(/creating/, out)
    assert_match(/container ready/, out)
  end

  # ===== infra_down =====

  def test_infra_down_removes
    calls = []
    bt = ->(cmd) {
      case cmd
      when /docker ps -a/ then BOSS
      else ''
      end
    }
    sys = ->(*args, **_) { calls << args; true }
    out, = capture_io {
      Kyb::CLI.stub(BT, bt) {
        Kyb::CLI.stub(:system, sys) { Kyb::CLI.infra_down }
      }
    }
    assert_match(/removed/, out)
    rm_call = calls.find { |a| a[0..1] == %w[docker rm] }
    assert rm_call, "expected docker rm, got: #{calls.inspect}"
    assert_equal '-f', rm_call[2]
    assert_equal BOSS, rm_call[3]
  end

  def test_infra_down_when_not_exists
    bt = ->(_cmd) { '' }
    any_called = false
    sys = ->(*args, **_) { any_called = true; true }
    out, = capture_io {
      Kyb::CLI.stub(BT, bt) {
        Kyb::CLI.stub(:system, sys) { Kyb::CLI.infra_down }
      }
    }
    assert_match(/does not exist/, out)
    refute any_called, 'system should not be called when container does not exist'
  end
end
