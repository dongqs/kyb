require_relative 'test_helper'

class DockerTest < Minitest::Test
  # --- container_name ---

  def test_container_name_with_default_branch
    assert_equal 'kyb-niao-kyb', Kyb::Docker.container_name('niao', 'kyb')
  end

  def test_container_name_with_branch
    assert_equal 'kyb-niao-water', Kyb::Docker.container_name('niao', 'water')
  end

  # --- port_in_use? ---

  def test_port_not_in_use
    refute Kyb::Docker.port_in_use?(29_001)
  end

  def test_port_in_use
    server = TCPServer.new('0.0.0.0', 29_002)
    assert Kyb::Docker.port_in_use?(29_002)
  ensure
    server&.close
  end

  # --- assign_ports ---

  def test_assign_ports_single_when_free
    mapping = Kyb::Docker.assign_ports([29_100])
    assert_equal '29100:29100', mapping
  end

  def test_assign_ports_multiple_when_all_free
    mapping = Kyb::Docker.assign_ports([29_200, 29_201])
    assert_equal '29200:29200,29201:29201', mapping
  end

  def test_assign_ports_skips_busy_port
    server = TCPServer.new('0.0.0.0', 29_300)
    mapping = Kyb::Docker.assign_ports([29_300])
    assert_equal '29301:29300', mapping
  ensure
    server&.close
  end

  def test_assign_ports_multiple_with_one_busy
    server = TCPServer.new('0.0.0.0', 29_400)
    mapping = Kyb::Docker.assign_ports([29_400, 29_500])
    assert_equal '29401:29400,29500:29500', mapping
  ensure
    server&.close
  end

  def test_assign_ports_empty_array
    assert_equal '', Kyb::Docker.assign_ports([])
  end

  # --- helpers ---

  # Stub File.exist? so that /.dockerenv returns the given boolean;
  # all other paths fall through to the real method.
  def with_dind(dind)
    real = File.method(:exist?)
    File.stub(:exist?, ->(p) { p == '/.dockerenv' ? dind : real.call(p) }) { yield }
  end

  def default_run_kwargs(overrides = {})
    {
      container: Kyb::Container.new('niao', 'sandbox'),
      image: 'kyb-base',
      repo_path: '/tmp/test-wt',
      project_name: 'niao',
      project_path: '/tmp/test-project',
      ports: '', symlinks: '', mounts_rw: '', mounts_ro: ''
    }.merge(overrides)
  end

  # Run Kyb::Docker.run under all necessary stubs (Dind detection + config).
  # Returns the captured docker CLI args array.
  def with_run_stubs(dind:, **run_kwargs)
    args = nil
    sys_stub = ->(*a) {
      args = a if a[0] == 'docker' && a[1] == 'run'
      true
    }
    real_exist = File.method(:exist?)
    Kyb::Docker.stub(:system, sys_stub) do
      File.stub(:exist?, ->(p) { p == '/.dockerenv' ? dind : real_exist.call(p) }) do
        Kyb::Config.stub(:claude_default_model, 'flash') do
        Kyb::Config.stub(:kyb_repo, nil) do
          Kyb::Docker.run(**run_kwargs)
        end
        end
      end
    end
    args
  end

  # --- build ---

  def test_build_sets_docker_buildkit
    captured_env = nil
    stub = ->(*args) { captured_env = args.first if args.first.is_a?(Hash); true }

    Kyb::Docker.stub(:system, stub) do
      Kyb::Docker.build('kyb-base', '/tmp')
    end

    assert_equal '1', captured_env['DOCKER_BUILDKIT']
  end

  # --- project_image ---

  def test_project_image_sets_docker_buildkit
    captured_env = nil
    stub = ->(*args) { captured_env = args.first if args.first.is_a?(Hash); true }

    Kyb::Docker.stub(:system, stub) do
      Kyb::Docker.project_image('niao', '/tmp/Dockerfile', '/tmp')
    end

    assert_equal '1', captured_env['DOCKER_BUILDKIT']
  end

  # --- run (normal mode) ---

  def test_run_mounts_kyb_dir
    kyb_dir = File.expand_path('~/.kyb')
    repo_path = '/tmp/test-wt-kyb'
    FileUtils.mkdir_p(repo_path)
    args = with_run_stubs(dind: false, **default_run_kwargs(repo_path: repo_path))
    assert args.each_cons(2).any? { |f, v| f == '-v' && v == "#{kyb_dir}:#{kyb_dir}" },
           "expected -v #{kyb_dir}:#{kyb_dir}"
  ensure
    FileUtils.rm_rf('/tmp/test-wt-kyb')
  end

  def test_run_normal_mode_binds_repo_path
    repo_path = '/tmp/test-wt-bind'
    FileUtils.mkdir_p(repo_path)
    args = with_run_stubs(dind: false, **default_run_kwargs(repo_path: repo_path))
    count = args.each_cons(2).count { |f, v| f == '-v' && v == "#{repo_path}:/home/dev/projects/niao" }
    assert_equal 1, count, 'expected exactly one bind mount for repo_path'
  ensure
    FileUtils.rm_rf('/tmp/test-wt-bind')
  end

  def test_run_binds_project_path_when_different
    pp = '/tmp/test-project-pp'
    repo_path = '/tmp/test-wt-pp'
    FileUtils.mkdir_p(repo_path)
    args = with_run_stubs(dind: false, **default_run_kwargs(repo_path: repo_path, project_path: pp))
    assert args.each_cons(2).any? { |f, v| f == '-v' && v == "#{pp}:#{pp}" },
           'expected project_path bind mount'
  ensure
    FileUtils.rm_rf('/tmp/test-wt-pp')
  end

  def test_run_skips_project_path_when_matches_wt_target
    # When project_path equals the mount target, only the repo_path bind mount
    # (line 115) should appear — NOT a second project_path mount (line 119).
    args = with_run_stubs(dind: false, **default_run_kwargs(
      repo_path: '/home/dev/projects/niao', project_path: '/home/dev/projects/niao'))
    mount_count = args.each_cons(2).count { |f, v| f == '-v' && v == '/home/dev/projects/niao:/home/dev/projects/niao' }
    assert_equal 1, mount_count, 'expected exactly one bind mount (from repo_path, not project_path)'
  end

  def test_run_passes_tz_env_var
    repo_path = '/tmp/test-wt-tz'
    FileUtils.mkdir_p(repo_path)
    args = with_run_stubs(dind: false, **default_run_kwargs(
      repo_path: repo_path, model: 'flash', timezone: 'America/Sao_Paulo'))
    assert args.each_cons(2).any? { |f, v| f == '-e' && v == 'TZ=America/Sao_Paulo' },
           'expected -e TZ=America/Sao_Paulo'
  ensure
    FileUtils.rm_rf('/tmp/test-wt-tz')
  end

  def test_run_passes_kyb_branch_env_var
    repo_path = '/tmp/test-wt-branch'
    FileUtils.mkdir_p(repo_path)
    args = with_run_stubs(dind: false, **default_run_kwargs(repo_path: repo_path, branch: 'sandbox'))
    assert args.each_cons(2).any? { |f, v| f == '-e' && v == 'KYB_BRANCH=sandbox' },
           'expected -e KYB_BRANCH=sandbox'
  ensure
    FileUtils.rm_rf('/tmp/test-wt-branch')
  end

  # --- run (DinD mode) ---

  def test_run_dind_uses_named_volume
    repo_path = '/tmp/test-wt-dind'
    FileUtils.mkdir_p(repo_path)
    args = with_run_stubs(dind: true, **default_run_kwargs(repo_path: repo_path))
    assert args.each_cons(2).any? { |f, v| f == '-v' && v == 'kyb-niao-sandbox-project:/home/dev/projects/niao' },
           'expected named volume in DinD mode'
  ensure
    FileUtils.rm_rf('/tmp/test-wt-dind')
  end

  def test_run_dind_skips_host_only_bind_mounts
    repo_path = '/tmp/test-wt-dind-skip'
    FileUtils.mkdir_p(repo_path)
    args = with_run_stubs(dind: true, **default_run_kwargs(repo_path: repo_path))

    bad_mounts = args.each_cons(2).select { |f, v| f == '-v' && (
      v.include?('/home/dev/.ssh') ||
      v.include?('/home/dev/.gitconfig') ||
      v.include?('/home/dev/.claude-host-settings') ||
      v.include?('/home/dev/.claude-skills-host') ||
      v.include?('/home/dev/.kimi') ||
      v.include?('/home/.agents') ||
      v.include?('/home/dev/.config/kyb')
    ) }
    assert_empty bad_mounts, "expected no host-only bind mounts in DinD mode, got: #{bad_mounts.map { |_, v| v }}"
  ensure
    FileUtils.rm_rf('/tmp/test-wt-dind-skip')
  end

  def test_run_dind_skips_project_path_and_symlinks
    repo_path = '/tmp/test-wt-dind-skip2'
    FileUtils.mkdir_p(repo_path)
    pp = '/tmp/test-project-pp2'
    args = with_run_stubs(dind: true, **default_run_kwargs(
      repo_path: repo_path, project_path: pp,
      symlinks: 'shared/vendor', mounts_rw: '/host/rw:/container/rw', mounts_ro: '/host/ro:/container/ro'))
    refute args.each_cons(2).any? { |f, v| f == '-v' && v == "#{pp}:#{pp}" },
           'project_path bind mount should be skipped in DinD'
    refute args.each_cons(2).any? { |f, v| f == '-v' && v == "#{pp}/shared/vendor:/home/dev/projects/niao/shared/vendor:ro" },
           'symlinks should be skipped in DinD'
    refute args.each_cons(2).any? { |f, v| f == '-v' && v == '/host/rw:/container/rw' },
           'mounts_rw should be skipped in DinD'
    refute args.each_cons(2).any? { |f, v| f == '-v' && v == '/host/ro:/container/ro:ro' },
           'mounts_ro should be skipped in DinD'
  ensure
    FileUtils.rm_rf('/tmp/test-wt-dind-skip2')
  end

  # --- run (Swift cache volume) ---

  def test_run_mounts_swift_cache_volume_when_exists
    skip 'docker not available' unless docker_available?
    # Ensure the volume exists (idempotent)
    system('docker', 'volume', 'create', 'kyb-swift-cache', out: File::NULL, err: File::NULL)
    repo_path = '/tmp/test-wt-swift'
    FileUtils.mkdir_p(repo_path)
    args = with_run_stubs(dind: false, **default_run_kwargs(repo_path: repo_path))
    assert args.each_cons(2).any? { |f, v| f == '-v' && v == 'kyb-swift-cache:/home/dev/.local/swift' },
           'expected kyb-swift-cache volume mount'
  ensure
    FileUtils.rm_rf('/tmp/test-wt-swift')
  end

  def test_run_skips_non_existent_volume
    skip 'docker not available' unless docker_available?
    unknown_vol = 'kyb-volet-xyxy'
    system('docker', 'volume', 'rm', unknown_vol, out: File::NULL, err: File::NULL) # ensure missing
    repo_path = '/tmp/test-wt-noswift'
    FileUtils.mkdir_p(repo_path)
    args = with_run_stubs(dind: false, **default_run_kwargs(repo_path: repo_path))
    refute args.each_cons(2).any? { |f, v| f == '-v' && v.include?(unknown_vol) },
           'expected no mount for non-existent volume'
  ensure
    FileUtils.rm_rf('/tmp/test-wt-noswift')
  end

  # --- run (kyb config mount) ---

  def test_run_mounts_kyb_config_when_dir_exists
    kyb_config = '/tmp/test-kyb-config'
    FileUtils.mkdir_p(kyb_config)
    real_expand = File.method(:expand_path)
    File.stub(:expand_path, ->(p) { p == '~/.config/kyb' ? kyb_config : real_expand.call(p) }) do
      repo_path = '/tmp/test-wt-cfg'
      FileUtils.mkdir_p(repo_path)
      args = with_run_stubs(dind: false, **default_run_kwargs(repo_path: repo_path))
      assert args.each_cons(2).any? { |f, v| f == '-v' && v == "#{kyb_config}:/home/dev/.config/kyb:ro" },
             'expected kyb config mount'
    end
  ensure
    FileUtils.rm_rf('/tmp/test-kyb-config')
    FileUtils.rm_rf('/tmp/test-wt-cfg')
  end

  def test_run_skips_kyb_config_when_dir_missing
    missing_path = '/tmp/test-kyb-config-missing'
    FileUtils.rm_rf(missing_path)
    real_expand = File.method(:expand_path)
    File.stub(:expand_path, ->(p) { p == '~/.config/kyb' ? missing_path : real_expand.call(p) }) do
      repo_path = '/tmp/test-wt-nocfg'
      FileUtils.mkdir_p(repo_path)
      args = with_run_stubs(dind: false, **default_run_kwargs(repo_path: repo_path))
      refute args.each_cons(2).any? { |f, v| f == '-v' && v.include?('kyb') && v.include?('config') },
             'expected no kyb config mount when dir missing'
    end
  ensure
    FileUtils.rm_rf('/tmp/test-wt-nocfg')
  end

  # --- run (mise/pip cache volumes) ---

  def test_run_mounts_mise_and_pip_cache_volumes
    repo_path = '/tmp/test-wt-cache'
    FileUtils.mkdir_p(repo_path)
    args = with_run_stubs(dind: false, **default_run_kwargs(repo_path: repo_path))
    assert args.each_cons(2).any? { |f, v| f == '-v' && v == 'kyb-mise-cache:/home/dev/.local/share/mise/downloads' },
           'expected kyb-mise-cache volume mount'
    assert args.each_cons(2).any? { |f, v| f == '-v' && v == 'kyb-pip-cache:/home/dev/.cache/pip' },
           'expected kyb-pip-cache volume mount'
  ensure
    FileUtils.rm_rf('/tmp/test-wt-cache')
  end

  # --- create_container (DinD worktree tar pipe) ---

  def stub_create_container_deps(cp_files_val = nil)
    Kyb::Config.stub(:load, nil) do
    Kyb::Config.stub(:project, ->(name) {
      { name: name, path: '/tmp/test-cp-project', base_branch: 'master', repo_root: 'shared_host_disk_mount',
        dockerfile: nil, ports: [], symlinks: '', mounts_rw: '', mounts_ro: '',
        cp_files: cp_files_val, cp_files_base_keys: [].freeze,
        extra_prompt: nil, timezone: 'Asia/Shanghai',
        proxy: nil, no_proxy: nil }
    }) do
    Kyb::Config.stub(:base_image_path, '/tmp') do
    Kyb::Docker.stub(:build, true) do
    Kyb::Docker.stub(:image_exists?, true) do
    Kyb::Docker.stub(:assign_ports, '') do
    Kyb::Docker.stub(:run, nil) do
    Kyb::Docker.stub(:exists?, false) do
    Kyb::Docker.stub(:running?, false) do
    FileUtils.stub(:mkdir_p, nil) do
      yield
    end; end; end; end; end; end; end; end; end; end
  end

  def test_ensure_master_synced_method_exists
    assert_respond_to Kyb::Docker, :ensure_master_synced
  end

  # --- create_container (cp_files) ---

  def test_create_container_cp_files_only_in_clone_mode
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, '.env.example'), "ENV=example\n")

      cp_pairs = []
      cp_stub = ->(src, dst) { cp_pairs << [src, dst]; nil }

      FileUtils.stub(:cp, cp_stub) do
      Kyb::Config.stub(:load, nil) do
      Kyb::Config.stub(:project, ->(name) {
        { name: name, path: tmpdir, base_branch: 'master',
          dockerfile: nil, ports: [], symlinks: '', mounts_rw: '', mounts_ro: '',
          cp_files: { '.env' => '.env.example' },
          cp_files_base_keys: [].freeze,
          extra_prompt: nil, timezone: 'Asia/Shanghai',
          proxy: nil, no_proxy: nil }
      }) do
      Kyb::Config.stub(:base_image_path, '/tmp') do
      Kyb::Docker.stub(:build, true) do
      Kyb::Docker.stub(:image_exists?, true) do
      Kyb::Docker.stub(:assign_ports, '') do
      Kyb::Docker.stub(:run, nil) do
      Kyb::Docker.stub(:exists?, false) do
      Kyb::Docker.stub(:running?, false) do
      Kyb::Docker.stub(:setup_clone, nil) do
      FileUtils.stub(:mkdir_p, nil) do
        # clone mode: cp_files should be called
        Kyb::Docker.create_container('niao', 'test', nil, model: nil, repo_root: 'isolated_local_repo_clone')
      end; end; end; end; end; end; end; end; end; end; end
      end
      refute cp_pairs.empty?, 'expected cp_files in clone mode'
    end
  end

  def test_create_container_cp_files_skips_missing
    Dir.mktmpdir do |tmpdir|
      cp_called = false
      cp_stub = ->(*args) { cp_called = true; nil }

      FileUtils.stub(:cp, cp_stub) do
      Kyb::Config.stub(:load, nil) do
      Kyb::Config.stub(:project, ->(name) {
        { name: name, path: tmpdir, base_branch: 'master',
          dockerfile: nil, ports: [], symlinks: '', mounts_rw: '', mounts_ro: '',
          cp_files: { '.env.kyb' => '.env.kyb', '.env.local' => '.env.local' },
          cp_files_base_keys: [].freeze,
          extra_prompt: nil, timezone: 'Asia/Shanghai',
          proxy: nil, no_proxy: nil }
      }) do
      Kyb::Config.stub(:base_image_path, '/tmp') do
      Kyb::Docker.stub(:build, true) do
      Kyb::Docker.stub(:image_exists?, true) do
      Kyb::Docker.stub(:assign_ports, '') do
      Kyb::Docker.stub(:run, nil) do
      Kyb::Docker.stub(:exists?, false) do
      Kyb::Docker.stub(:running?, false) do
      FileUtils.stub(:mkdir_p, nil) do
        Kyb::Docker.create_container('niao', 'test')
      end; end; end; end; end; end; end; end; end; end
      end
      refute cp_called, 'FileUtils.cp should not be called when all source files are missing'
    end
  end

  def test_create_container_cp_files_nil_skips_copy
    # When cp_files is nil (not configured), no FileUtils.cp should be triggered
    cp_called = false
    sys_stub = ->(*args) { true }

    Kyb::Docker.stub(:system, sys_stub) do
    FileUtils.stub(:cp, ->(*args) { cp_called = true; nil }) do
    stub_create_container_deps(nil) do
      Kyb::Docker.create_container('niao', 'water')
    end; end; end

    refute cp_called, 'FileUtils.cp should not be called when cp_files is nil'
  end

  def test_create_container_normal_skips_cp
    cp_called = false
    sys_stub = ->(*args) { cp_called = true if args[0] == 'docker' && args[1] == 'cp'; true }

    with_dind(false) do
      Kyb::Docker.stub(:system, sys_stub) do
        stub_create_container_deps do
          Kyb::Docker.create_container('niao', 'water')
        end
      end
    end

    refute cp_called, 'docker cp should NOT be called in normal mode'
  end

  def test_create_container_dind_tar_pipe_injects_host_files
    Dir.mktmpdir do |tmpdir|
      FileUtils.mkdir_p("#{tmpdir}/.ssh")
      FileUtils.touch("#{tmpdir}/.gitconfig")
      FileUtils.mkdir_p("#{tmpdir}/.config/kyb")

      tar_cmd = nil
      sys_stub = ->(*args) {
        if args[0] == 'bash' && args[1] == '-c' && args[2]&.include?('.ssh')
          tar_cmd = args[2]
        end
        true
      }

      Dir.stub(:home, -> { tmpdir }) do
      with_dind(true) do
        Kyb::Docker.stub(:system, sys_stub) do
          stub_create_container_deps do
            Kyb::Docker.create_container('niao', 'water')
          end
        end
      end; end

      refute_nil tar_cmd, 'expected tar pipe command in DinD mode'
      assert tar_cmd.include?('.ssh'), 'tar pipe should include .ssh'
      assert tar_cmd.include?('.gitconfig'), 'tar pipe should include .gitconfig'
      assert tar_cmd.include?('.config/kyb'), 'tar pipe should include .config/kyb'
    end
  end

  def docker_available?
    system('docker', 'version', out: File::NULL, err: File::NULL)
  end
end
