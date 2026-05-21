# frozen_string_literal: true

require_relative 'test_helper'

#
# Verify README.md claims against actual implementation.
#
# These tests detect documentation drift: when a README claim no longer
# matches the code, the test fails, flagging a doc update.
#

class ReadmeTest < Minitest::Test
  # -- CLI Commands ---------------------------------------------------------

  README_COMMANDS = %w[build create ps enter exec stop start rm prune
                       did notify].freeze

  def test_readme_commands_are_in_dispatch
    src = File.read(File.expand_path('../lib/kyb/cli.rb', __dir__))
    README_COMMANDS.each do |cmd|
      # The dispatch case statement should have a `when` for each command
      assert_match(/when\s+'#{cmd}'/, src,
                   "README mentions `#{cmd}` but dispatch doesn't handle it")
    end
  end

  def test_help_mentions_all_readme_commands
    src = File.read(File.expand_path('../lib/kyb/cli.rb', __dir__))
    README_COMMANDS.each do |cmd|
      next if %w[ps notify].include?(cmd) # ps is listed as "ps, ls"; notify separately
      assert_match(/\b#{cmd}\b/, src[/^  def help$.*?^  end$/m],
                   "README mentions `#{cmd}` but help text doesn't")
    end
  end

  def test_readme_port_notation_is_inaccurate
    # README shows `create NAME [PORT]`, `enter NAME [PORT]`, etc.
    # But actual CLI does NOT accept a bare PORT argument for enter/stop/start/rm.
    # Only `create` accepts `--ports HOST:CONTAINER`.
    src = File.read(File.expand_path('../lib/kyb/cli.rb', __dir__))
    # All non-create commands should not have PORT logic
    assert_match(/create.*--ports/, src, 'create should accept --ports')
    # enter, stop, start, rm should reference PROJECT-BRANCH not a bare port
    assert_match(/enter.*PROJECT-BRANCH/, src)
    assert_match(/rm.*PROJECT-BRANCH/, src)
  end

  # -- Commands in code but NOT in README -----------------------------------

  def test_undocumented_commands
    # These commands exist in dispatch but aren't listed in README CLI section.
    # When README is updated to include them, remove from this list.
    dispatch_src = File.read(File.expand_path('../lib/kyb/cli.rb', __dir__))
    undocumented = %w[init tts session version]
    undocumented.each do |cmd|
      assert_match(/when\s+'#{cmd}'/, dispatch_src,
                   "#{cmd} should be in dispatch (check if README documents it now)")
    end
    # `ls` is handled as `when 'ps', 'ls'`
    assert_match(/when 'ps', 'ls'/, dispatch_src,
                 'ls is an alias for ps in dispatch')
  end

  # -- Config options in README match code ----------------------------------

  def test_config_keys_documented_in_readme
    src = File.read(File.expand_path('../lib/kyb/config.rb', __dir__))
    # Each documented config key should be accessed in Config.project
    %w[path git_url base_branch ports symlinks mounts_rw mounts_ro
       timezone dockerfile cp_files proxy no_proxy
       sandbox_allowed_domains extra_prompt].each do |key|
      assert_match(/\b#{key}\b/, src,
                   "Config key '#{key}' is documented in README but not accessed in config.rb")
    end
  end

  def test_config_base_keys
    src = File.read(File.expand_path('../lib/kyb/config.rb', __dir__))
    %w[image kyb_repo proxy no_proxy claude_default_model cp_files].each do |key|
      assert_match(/\bdig\('base', '#{key}'\)/, src,
                   "Base config key '#{key}' is documented in README but not read in config.rb")
    end
  end

  def test_project_returns_all_documented_keys
    stub_data = {
      'base' => {},
      'projects' => { 'x' => { 'path' => '~/x', 'base_branch' => 'main' } }
    }
    Kyb::Config.stub(:load, stub_data) do
      Kyb::Config.stub(:load_config, stub_data) do
        proj = Kyb::Config.project('x')
        expected_keys = %i[name path git_url base_branch dockerfile ports
                           symlinks mounts_rw mounts_ro cp_files cp_files_base_keys
                           timezone proxy no_proxy sandbox_allowed_domains extra_prompt]
        expected_keys.each do |key|
          assert proj.key?(key), "Config.project result missing key :#{key}"
        end
      end
    end
  end

  # -- env_template deprecation ---------------------------------------------

  def test_env_template_deprecation
    assert_respond_to Kyb::Config, :build_cp_files
    # env_template should convert to cp_files .env entry
    result = Kyb::Config.send(:build_cp_files, { 'env_template' => '.env.example' })
    assert_equal '.env.example', result['.env']
  end

  def test_env_template_conflict_with_cp_files
    assert_raises(SystemExit) do
      Kyb::Config.send(:build_cp_files, { 'cp_files' => { '.env' => '.env.local' }, 'env_template' => '.env.example' })
    end
  end

  # -- Volume names & mount points ------------------------------------------

  SHARED_CACHE = {
    'kyb-gradle-cache' => '/home/dev/.gradle',
    'kyb-maven-cache'  => '/home/dev/.m2/repository',
    'kyb-mise-cache'   => '/home/dev/.local/share/mise/downloads',
    'kyb-pip-cache'    => '/home/dev/.cache/pip',
    'kyb-swift-cache'  => '/home/dev/.local/swift'
  }.freeze

  def test_shared_volumes_in_docker_run
    src = File.read(File.expand_path('../lib/kyb/docker.rb', __dir__))
    SHARED_CACHE.each do |vol, mnt|
      assert_match(/#{Regexp.escape(vol)}.*#{Regexp.escape(mnt)}/m, src,
                   "Volume #{vol} not mounted at #{mnt} in docker.rb")
    end
  end

  def test_shared_volumes_in_did_create
    src = File.read(File.expand_path('../lib/kyb/cli/did.rb', __dir__))
    SHARED_CACHE.each do |vol, mnt|
      next if vol == 'kyb-swift-cache' # optional, only if volume exists
      assert_match(/#{Regexp.escape(vol)}.*#{Regexp.escape(mnt)}/m, src,
                   "Volume #{vol} not mounted at #{mnt} in did.rb")
    end
  end

  # -- Container naming -----------------------------------------------------

  def test_container_label
    assert_equal 'kyb=true', Kyb::Container::LABEL
  end

  def test_container_filter
    assert_equal 'name=kyb-', Kyb::Container.filter
  end

  def test_base_image_name
    assert_equal 'kyb-base', Kyb::Container::BASE_IMAGE
  end

  def test_build_hash_files
    assert_includes Kyb::Docker::BUILD_HASH_FILES, 'Dockerfile'
    assert_includes Kyb::Docker::BUILD_HASH_FILES, 'entrypoint.sh'
  end

  def test_container_naming
    c = Kyb::Container.new('myproj', 'feat-x')
    assert_equal 'kyb-myproj-feat-x', c.name
    assert_equal 'kyb/myproj-feat-x', c.git_branch
  end

  def test_container_volumes
    c = Kyb::Container.new('myproj', 'feat-x')
    assert_equal 'kyb-myproj-feat-x-claude', c.claude_volume
    assert_equal 'kyb-myproj-feat-x-home', c.home_volume
    assert_equal 'myproj-node_modules', c.node_modules_volume
  end

  # -- Build command --------------------------------------------------------

  def test_build_checks_dockerfile_exists
    src = File.read(File.expand_path('../lib/kyb/cli/build.rb', __dir__))
    assert_match(/File\.exist\?\(dockerfile\)/, src,
                 'build should check Dockerfile exists before running docker build')
    assert_match(/Dockerfile not found/, src)
  end

  def test_dockerfile_handles_arch
    src = File.read(File.expand_path('../Dockerfile', __dir__))
    assert_match(/TARGETARCH/, src, 'Dockerfile should detect architecture for mirror selection')
    assert_match(/arm64/, src, 'Dockerfile should handle ARM64')
    assert_match(/archive\.ubuntu/, src, 'Dockerfile should have fallback for AMD64')
  end

  # -- Config defaults ------------------------------------------------------

  def test_default_timezone
    src = File.read(File.expand_path('../lib/kyb/config.rb', __dir__))
    assert_match(/timezone.*\|\|.*Asia\/Shanghai/, src)
  end

  def test_default_claude_model
    assert_equal 'flash', Kyb::Config.claude_default_model
  end

  # -- Sandbox allowed domains ----------------------------------------------

  README_DOMAINS = %w[
    *.npmjs.org *.npmmirror.com registry.npmjs.org registry.npmmirror.com
    github.com *.github.com *.githubusercontent.com
    git.leyantech.com *.leyantech.com nexus.leyantech.com
    api.anthropic.com api.deepseek.com *.deepseek.com
    localhost 127.0.0.1
  ].freeze

  def test_sandbox_allowed_domains_defaults
    assert_equal README_DOMAINS.sort, Kyb::Config::DEFAULT_SANDBOX_DOMAINS.sort
  end

  # -- Host mounts ----------------------------------------------------------

  def test_ssh_mount
    src = File.read(File.expand_path('../lib/kyb/docker.rb', __dir__))
    assert_includes src, '/home/dev/.ssh'
  end

  def test_gitconfig_mount
    src = File.read(File.expand_path('../lib/kyb/docker.rb', __dir__))
    assert_includes src, 'gitconfig'
  end

  def test_claude_settings_mount
    src = File.read(File.expand_path('../lib/kyb/docker.rb', __dir__))
    assert_includes src, 'claude-host-settings'
  end

  def test_kyb_config_mount
    src = File.read(File.expand_path('../lib/kyb/docker.rb', __dir__))
    assert_includes src, '/home/dev/.config/kyb'
  end

  def test_claude_skills_mount
    src = File.read(File.expand_path('../lib/kyb/docker.rb', __dir__))
    assert_includes src, 'claude-skills-host'
  end

  def test_docker_sock_mount
    src = File.read(File.expand_path('../lib/kyb/docker.rb', __dir__))
    assert_includes src, '/var/run/docker.sock'
  end

  def test_repo_mounts_project_specific_path
    src = File.read(File.expand_path('../lib/kyb/docker.rb', __dir__))
    # Each project is mounted individually: repo_path → /home/dev/projects/<project_name>
    # The entire ~/projects host directory is NOT mounted as a single mount.
    assert_match(%r{repo_path.*projects/\#\{project_name\}}, src,
                 'Repo mounts to project-specific path, not bare /home/dev/projects')
  end

  def test_dind_guards_host_mounts
    src = File.read(File.expand_path('../lib/kyb/docker.rb', __dir__))
    # The `unless dind` block contains host-specific mounts
    assert_match(/unless dind/, src)
    # gitconfig and claude-host-settings only in docker.rb (not in DinD code)
    assert_includes src, '.gitconfig'
    assert_includes src, 'claude-host-settings'
  end

  # -- PostgreSQL claim -----------------------------------------------------

  def test_postgresql_trust_auth
    src = File.read(File.expand_path('../Dockerfile', __dir__))
    assert_match(/local all all trust/, src)
    assert_match(/host all all 127\.0\.0\.1\/32 trust/, src)
    assert_match(/host all all ::1\/128 trust/, src)
  end

  def test_postgresql_timezone
    src = File.read(File.expand_path('../Dockerfile', __dir__))
    assert_match(%r{timezone = 'Asia/Shanghai'}, src)
  end

  def test_postgresql_started_by_entrypoint
    src = File.read(File.expand_path('../entrypoint.sh', __dir__))
    assert_match(/pg_ctlcluster 16 main start/, src)
  end

  # -- Entrypoint CLAUDE.md generation --------------------------------------

  def test_entrypoint_generates_claude_md
    src = File.read(File.expand_path('../entrypoint.sh', __dir__))
    assert_match(/kyb Sandbox/, src)
    assert_match(/kyb notify done\|blocked\|urgent/, src)
    assert_match(/PostgreSQL 16/, src)
    assert_match(/ClickHouse/, src)
    assert_match(/mise.*Node.*Ruby.*Java/, src)
  end

  # -- Network architecture -------------------------------------------------

  def test_dockerfile_clears_proxy_at_end
    src = File.read(File.expand_path('../Dockerfile', __dir__))
    # Proxy must be set first then cleared at the end
    first_all_proxy = src.index('ALL_PROXY=')
    last_all_proxy = src.rindex('ALL_PROXY=')
    refute_nil first_all_proxy
    refute_nil last_all_proxy
    refute_equal first_all_proxy, last_all_proxy,
                 'ALL_PROXY should be set and then cleared (two occurrences)'
    # The last occurrence should be the cleared one (ALL_PROXY= with nothing after)
    after_last = src[last_all_proxy..last_all_proxy + 20]
    assert_match(/ALL_PROXY=\s/, after_last, 'Final ALL_PROXY should be empty')
  end

  def test_no_proxy_includes_intranet
    src = File.read(File.expand_path('../Dockerfile', __dir__))
    assert_match(/\.leyantech\.com/, src)
    assert_match(/localhost/, src)
    assert_match(/127\.0\.0\.1/, src)
    assert_match(/host\.orb\.internal/, src)
  end

  # -- Worktree isolation ---------------------------------------------------

  def test_container_has_git_branch
    c = Kyb::Container.new('proj', 'branch')
    assert_equal 'kyb/proj-branch', c.git_branch
  end

  # -- git_url config -------------------------------------------------------

  def test_git_url_config
    assert_respond_to Kyb::Config, :project
    stub_data = {
      'base' => {},
      'projects' => { 'x' => { 'path' => '~/x', 'base_branch' => 'main',
                                'git_url' => 'git@github.com:user/repo.git' } }
    }
    Kyb::Config.stub(:load, stub_data) do
      Kyb::Config.stub(:load_config, stub_data) do
        proj = Kyb::Config.project('x')
        assert_equal 'git@github.com:user/repo.git', proj[:git_url]
      end
    end
  end

  # -- NOTIFY command -------------------------------------------------------

  def test_notify_levels
    src = File.read(File.expand_path('../lib/kyb/cli.rb', __dir__))
    assert_match(/level must be done\/blocked\/urgent/, src)
  end

  # -- Alias ps/ls ----------------------------------------------------------

  def test_ps_has_ls_alias
    assert_respond_to Kyb::CLI, :ls
  end
end
