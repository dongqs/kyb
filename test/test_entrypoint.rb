require_relative 'test_helper'

class EntrypointTest < Minitest::Test
  IMAGE = 'kyb-base'
  CONTAINER = 'kyb-test-entrypoint'

  def setup
    skip 'entrypoint tests require Docker and kyb-base image (CI)' if ENV['CI']
    # Skip if base image missing
    skip "#{IMAGE} not found — build it first with `kyb build`" unless
      system('docker', 'image', 'inspect', IMAGE,
             out: File::NULL, err: File::NULL)
    cleanup_container
  end

  def teardown
    cleanup_container
  end

  def test_kyb_ready_sentinel
    start_container
    assert(sentinel?,
           '/tmp/kyb-ready should exist after entrypoint completes')
  end

  def test_home_dev_owned_by_dev
    start_container
    uid = uid_dev
    gid = gid_dev
    home_owner = exec('stat', '-c', '%u:%g', '/home/dev')
    assert_equal("#{uid}:#{gid}", home_owner,
                 '/home/dev should be owned by dev:dev')
  end

  def test_postgresql_runs_in_non_did
    start_container
    assert(exec_bool('pg_isready'),
           'PostgreSQL should be auto-started for non-DID containers')
  end

  def test_postgresql_not_running_in_did
    cname = "#{CONTAINER}-did"

    system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
    system('docker', 'run', '-d', '--name', cname,
           '-e', 'KYB_DID=1',
           '-e', 'HOST_UID=1000', '-e', 'HOST_GID=1000',
           IMAGE, 'sleep', '300',
           out: File::NULL, err: File::NULL)
    wait_for_ready(cname)

    refute(exec_bool_in(cname, 'pg_isready'),
           'PostgreSQL should not auto-start in DID containers')
    system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
  end

  def test_pip_packages_installed
    start_container
    assert(exec_user_bool('bash', '-l', '-c',
                          'pip show mig25 >/dev/null 2>&1'),
           'mig25 should be installed via pip')
    assert(exec_user_bool('bash', '-l', '-c',
                          'pip show requests >/dev/null 2>&1'),
           'requests should be installed via pip')
  end

  def test_entrypoint_exit_code_zero
    # Verify entrypoint script itself is syntactically valid
    assert(system('docker', 'run', '--rm', '--entrypoint', 'bash', IMAGE,
                  '-n', '/usr/local/bin/entrypoint.sh',
                  out: File::NULL, err: File::NULL),
           'entrypoint.sh should pass bash syntax check')
  end

  def test_chown_fast_path_default_uid
    start_container
    # With default HOST_UID/HOST_GID (same as image), chown is skipped.
    # Everything should still be owned correctly from image build.
    assert_equal('dev', exec('stat', '-c', '%U', '/home/dev'),
                 '/home/dev owner should be dev with default UID')

    # Verify SSH/config dirs exist (copied by did.rb post-wait, but
    # /home/dev itself should be properly owned from image build)
    assert_equal('dev', exec('stat', '-c', '%U', '/home/dev/.claude'),
                 '/home/dev/.claude should exist and be owned by dev')
  end

  def test_chown_runs_when_uid_changed
    cname = "#{CONTAINER}-uidchange"

    system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
    system('docker', 'run', '-d', '--name', cname,
           '-e', 'HOST_UID=9999',
           '-e', 'HOST_GID=9999',
           IMAGE, 'sleep', '300',
           out: File::NULL, err: File::NULL)
    wait_for_ready(cname)

    uid = exec_in(cname, 'id', '-u', 'dev')
    assert_equal('9999', uid, 'dev UID should be remapped to HOST_UID=9999')

    home_owner = exec_in(cname, 'stat', '-c', '%u:%g', '/home/dev')
    assert_equal('9999:9999', home_owner,
                 '/home/dev should be re-chowned when UID/GID changes')

    system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
  end


  # --- Issue #14: gh CLI ---
  def test_gh_installed
    start_container
    assert(exec_user_bool('bash', '-l', '-c', 'gh --version >/dev/null 2>&1'), 'gh should be installed')
  end

  def test_github_token_auth
    cname = "#{CONTAINER}-ghtoken"
    system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
    system('docker', 'run', '-d', '--name', cname, '-e', 'GITHUB_TOKEN=test-token-123', '-e', 'HOST_UID=1000', '-e', 'HOST_GID=1000', IMAGE, 'sleep', '300', out: File::NULL, err: File::NULL)
    wait_for_ready(cname)
    gh_config = exec_in(cname, 'bash', '-l', '-c', 'cat /home/dev/.config/gh/hosts.yml 2>/dev/null || echo NOFILE')
    refute_equal('NOFILE', gh_config.strip, 'gh hosts.yml should be created when GITHUB_TOKEN is set')
    assert_includes(gh_config, 'test-token-123', 'gh config should contain the provided GITHUB_TOKEN')
    system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
  end

  # --- Issue #22: .ssh copy ---
  def test_ssh_host_copied
    vol = 'kyb-test-ssh-host'
    system('docker', 'volume', 'create', vol, out: File::NULL, err: File::NULL)
    system('docker', 'run', '--rm', '--entrypoint', 'bash', '-v', "#{vol}:/data", IMAGE, '-c', 'mkdir -p /data && touch /data/id_rsa /data/known_hosts /data/config', out: File::NULL, err: File::NULL)
    cname = "#{CONTAINER}-ssh-copy"
    system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
    system('docker', 'run', '-d', '--name', cname, '-v', "#{vol}:/home/dev/.ssh-host:ro", '-e', 'HOST_UID=1000', '-e', 'HOST_GID=1000', IMAGE, 'sleep', '300', out: File::NULL, err: File::NULL)
    wait_for_ready(cname)
    assert(exec_bool_in(cname, 'test', '-f', '/home/dev/.ssh/id_rsa'), '.ssh/id_rsa should exist')
    assert(exec_bool_in(cname, 'test', '-f', '/home/dev/.ssh/known_hosts'), '.ssh/known_hosts should exist')
    assert_equal('dev', exec_in(cname, 'stat', '-c', '%U', '/home/dev/.ssh/id_rsa'), 'files should be owned by dev')
    system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
    system('docker', 'volume', 'rm', vol, out: File::NULL, err: File::NULL)
  end

  # --- Issue #11: DID toolchain ---
  def test_did_root_toolchain
    cname = "#{CONTAINER}-did-root"
    system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
    system('docker', 'run', '-d', '--name', cname, '-e', 'KYB_DID=1', '-e', 'HOST_UID=1000', '-e', 'HOST_GID=1000', IMAGE, 'sleep', '300', out: File::NULL, err: File::NULL)
    wait_for_ready(cname)
    assert_equal('/home/dev/.m2/settings.xml', exec_in(cname, 'readlink', '-f', '/root/.m2/settings.xml'), "root Maven settings should symlink to dev's")
    assert_equal('/home/dev/.m2/repository', exec_in(cname, 'readlink', '-f', '/root/.m2/repository'), "root Maven repo should symlink to dev's")
    assert_equal('/home/dev/.gradle', exec_in(cname, 'readlink', '-f', '/root/.gradle'), "root Gradle should symlink to dev's")
    bashrc = exec_in(cname, 'cat', '/root/.bashrc')
    assert_includes(bashrc, 'mise activate', "root .bashrc should have mise activation")
    assert_includes(bashrc, '/home/dev/.local/bin', "root .bashrc should include dev local bin")
    system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
  end

  private

  def start_container
    return if container_running?
    system('docker', 'run', '-d', '--name', CONTAINER,
           IMAGE, 'sleep', '300',
           out: File::NULL, err: File::NULL) ||
      raise("Failed to start container #{CONTAINER}")
    wait_for_ready
  end

  def wait_for_ready(cname = CONTAINER, timeout = 30)
    timeout.times do
      return if exec_bool_in(cname, 'test', '-f', '/tmp/kyb-ready')
      sleep 0.5
    end
    flunk("Container #{cname} not ready after #{timeout * 0.5}s")
  end

  def container_running?
    `docker ps --format '{{.Names}}'`.lines.map(&:strip).include?(CONTAINER)
  end

  def cleanup_container
    system('docker', 'rm', '-f', CONTAINER,
           out: File::NULL, err: File::NULL)
  end

  # -- helpers for exec into CONTAINER --

  def exec(*args)
    exec_in(CONTAINER, *args)
  end

  def exec_in(cname, *args)
    IO.popen(['docker', 'exec', cname, *args], &:read)&.strip || ''
  end

  def exec_bool(*args)
    exec_bool_in(CONTAINER, *args)
  end

  def exec_bool_in(cname, *args)
    system('docker', 'exec', cname, *args,
           out: File::NULL, err: File::NULL)
  end

  def exec_user_bool(*args)
    system('docker', 'exec', '-u', 'dev', CONTAINER, *args,
           out: File::NULL, err: File::NULL)
  end

  def sentinel?
    exec_bool_in(CONTAINER, 'test', '-f', '/tmp/kyb-ready')
  end

  def uid_dev
    exec('id', '-u', 'dev')
  end

  def gid_dev
    exec('id', '-g', 'dev')
  end
end
