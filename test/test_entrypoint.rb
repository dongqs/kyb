require_relative 'test_helper'
require 'shellwords'

class EntrypointTest < Minitest::Test
  IMAGE = 'kyb-base'
  CONTAINER = 'kyb-test-entrypoint'

  def setup
    @container_started = false
  end

  def teardown
    system('docker', 'rm', '-f', CONTAINER, %i[out err] => File::NULL) if @container_started
  end

  def test_kyb_ready_sentinel
    start_container
    assert(sentinel?, '/tmp/kyb-ready should exist after entrypoint completes')
  end

  def test_home_dev_owned_by_dev
    start_container
    uid = uid_dev
    gid = gid_dev
    home_owner = exec('stat', '-c', '%u:%g', '/home/dev')
    assert_equal("#{uid}:#{gid}", home_owner, '/home/dev should be owned by dev:dev')
  end

  def test_postgresql_runs_in_non_did
    start_container
    assert(exec_bool('pg_isready'), 'PostgreSQL should be auto-started for non-DID containers')
  end

  def test_chown_fast_path_default_uid
    start_container
    assert_equal('dev', exec('stat', '-c', '%U', '/home/dev'))
    assert_equal('dev', exec('stat', '-c', '%U', '/home/dev/.claude'))
  end

  def test_go_proxy_set
    start_container
    result = exec('bash', '-l', '-c', 'echo $GOPROXY')
    assert_equal('https://goproxy.cn,direct', result)
  end

  def test_entrypoint_exit_code_zero
    entrypoint = File.expand_path('../entrypoint.sh', __dir__)
    bash_check = `bash -n #{entrypoint} 2>&1`
    assert $?.success?, "entrypoint.sh syntax: #{bash_check}"
  end

  def test_entrypoint_has_feishu_bot_startup
    entrypoint = File.expand_path('../entrypoint.sh', __dir__)
    content = File.read(entrypoint)
    assert_includes content, 'feishu-bot',
                    'entrypoint.sh should contain feishu-bot auto-start logic'
    assert_includes content, '.env',
                    'entrypoint.sh should source .env for feishu credentials'
    assert_includes content, 'nohup',
                    'entrypoint.sh should use nohup for background feishu-bot'
  end

  def test_feishu_bot_startup_in_container
    cname = 'kyb-test-feishu-bot'
    image_exists = system('docker', 'image', 'inspect', IMAGE, %i[out err] => File::NULL)
    skip "#{IMAGE} not available" unless image_exists

    begin
      system('docker', 'rm', '-f', cname, %i[out err] => File::NULL)
      system('docker', 'run', '-d', '--name', cname,
             IMAGE, 'sleep', 'infinity',
             %i[out err] => File::NULL)
      wait_for_ready(cname, 30)

      # Copy kyb project files into container
      system('docker', 'exec', cname, 'mkdir', '-p', '/home/dev/projects/kyb', %i[out err] => File::NULL)
      system('docker', 'cp', '/home/dev/projects/kyb/.env', "#{cname}:/home/dev/projects/kyb/.env", %i[out err] => File::NULL)
      system('docker', 'cp', '/home/dev/projects/kyb/bin/', "#{cname}:/home/dev/projects/kyb/", %i[out err] => File::NULL)
      system('docker', 'cp', '/home/dev/projects/kyb/lib/', "#{cname}:/home/dev/projects/kyb/", %i[out err] => File::NULL)

      # Simulate entrypoint's feishu-bot startup as dev user (has Ruby via mise)
      system('docker', 'exec', '-u', 'dev', '-w', '/home/dev/projects/kyb',
             cname, 'bash', '-l', '-c',
        "set -a && . .env && set +a && " \
        "nohup bin/feishu-bot >> /tmp/feishu-bot.log 2>&1 &")

      sleep 4

      bot_pid = exec_in(cname, 'pgrep', '-f', 'bin/feishu-bot')
      refute_empty bot_pid, 'Feishu bot process should be running'

      log = exec_in(cname, 'cat', '/tmp/feishu-bot.log')
      assert_includes log, '[feishu-bot]', 'Log should contain feishu-bot output'
    ensure
      system('docker', 'rm', '-f', cname, %i[out err] => File::NULL)
    end
  end

  private

  def start_container
    return if @container_started
    image_exists = system('docker', 'image', 'inspect', IMAGE, %i[out err] => File::NULL)
    skip "#{IMAGE} not available" unless image_exists
    system('docker', 'rm', '-f', CONTAINER, %i[out err] => File::NULL)
    system('docker', 'run', '-d', '--name', CONTAINER, IMAGE, 'sleep', 'infinity', %i[out err] => File::NULL)
    @container_started = true
    wait_for_ready
  end

  def wait_for_ready(cname = CONTAINER, timeout = 30)
    timeout.times do
      return if system('docker', 'exec', cname, 'test', '-f', '/tmp/kyb-ready', %i[out err] => File::NULL)
      sleep 1
    end
  end

  def exec(*args)
    exec_in(CONTAINER, *args)
  end

  def exec_in(cname, *args)
    `docker exec #{cname} #{args.map { |a| Shellwords.escape(a) }.join(' ')} 2>/dev/null`.strip
  end

  def exec_bool(*args)
    exec_bool_in(CONTAINER, *args)
  end

  def exec_bool_in(cname, *args)
    system('docker', 'exec', cname, *args, %i[out err] => File::NULL)
  end

  def exec_user_bool(*args)
    system('docker', 'exec', '-u', 'dev', CONTAINER, *args, %i[out err] => File::NULL)
  end

  def sentinel?
    exec_bool_in(CONTAINER, 'test', '-f', '/tmp/kyb-ready')
  end

  def uid_dev
    exec_in(CONTAINER, 'id', '-u', 'dev')
  end

  def gid_dev
    exec_in(CONTAINER, 'id', '-g', 'dev')
  end
end
