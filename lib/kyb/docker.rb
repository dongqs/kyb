# frozen_string_literal: true

module Kyb::Docker
  module_function

  def build(tag, path)
    puts "==> Building base image: #{tag}"
    env = { 'DOCKER_BUILDKIT' => '1' }
    system(env, 'docker', 'build', '-t', tag, path.to_s) || Kyb.die('docker build failed')
  end

  def project_image(name, dockerfile, context)
    image = Kyb::Container.new(name, nil).project_image
    puts "==> #{name}: building project image (#{dockerfile})"
    env = { 'DOCKER_BUILDKIT' => '1' }
    system(env, 'docker', 'build', '-t', image, '-f', dockerfile.to_s, context.to_s) || Kyb.die('docker build failed')
    image
  end

  def container_name(project, branch)
    Kyb::Container.new(project, branch).name
  end

  def assign_ports(container_ports)
    container_ports.map do |cport|
      hport = cport
      hport += 1 while port_in_use?(hport)
      "#{hport}:#{cport}"
    end.join(',')
  end

  def port_in_use?(port)
    TCPServer.new('0.0.0.0', port).close
    false
  rescue Errno::EADDRINUSE
    true
  end

  def running?(container)
    `docker ps --format '{{.Names}}'`.lines.map(&:strip).include?(container)
  end

  def exists?(container)
    `docker ps -a --format '{{.Names}}'`.lines.map(&:strip).include?(container)
  end

  def ps_list
    out = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter '#{Kyb::Container.filter}' 2>/dev/null`
    return [] if out.strip.empty?
    out.lines.map { |l| l.strip.split("\t", 3) }
  end

  def remove_container(container)
    if exists?(container)
      puts "==> #{container}: removing container"
      system('docker', 'rm', '-f', container)
    else
      puts "==> #{container}: container not found, skip"
    end
  end

  def volume_rm(volume)
    return unless system('docker', 'volume', 'ls', '-q', out: File::NULL) &&
                  `docker volume ls -q`.lines.map(&:strip).include?(volume)
    puts "==> #{volume}: removing volume"
    system('docker', 'volume', 'rm', volume)
  end

  def containers_for_project(name)
    out = `docker ps -a --format '{{.Names}}' --filter 'name=kyb-#{name}' 2>/dev/null`
    out.lines.map(&:strip).reject(&:empty?)
  end

  def run(container:, image:, wt_path:, project_name:, project_path:, ports:, symlinks:, mounts_rw:, mounts_ro:, model: nil, timezone: 'Asia/Shanghai', kyb_proxy: nil, kyb_no_proxy: nil)
    puts "==> #{container.name}: starting (#{wt_path} -> /home/dev/projects/#{project_name})"

    args = %w[docker run -d]
    args += ['--name', container.name]
    args += ['--hostname', container.hostname]
    args += ['-e', "HOST_UID=#{Process.uid}"]
    args += ['-e', "HOST_GID=#{Process.gid}"]
    args += ['-e', "GITLAB_TOKEN=#{ENV['GITLAB_TOKEN']}"]
    args += ['-e', "CLAUDE_CODE_ATTRIBUTION_HEADER=#{ENV['CLAUDE_CODE_ATTRIBUTION_HEADER']}"]
    args += ['-e', "CLAUDE_CODE_EFFORT_LEVEL=#{ENV['CLAUDE_CODE_EFFORT_LEVEL']}"]
    args += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"]
    args += ['-e', "KYB_PROJECT=#{project_name}"]
    args += ['-e', "KYB_MODEL=#{model || Kyb::Config.claude_default_model}"]
    args += ['-e', "TZ=#{timezone}"]
    args += ['-e', "KYB_PROXY=#{kyb_proxy}"] if kyb_proxy
    args += ['-e', "KYB_NO_PROXY=#{kyb_no_proxy}"] if kyb_no_proxy
    args += ['-l', Kyb::Container::LABEL]

    ssh_dir = File.expand_path('~/.ssh')
    args += ['-v', "#{ssh_dir}:/home/dev/.ssh:ro"] if File.directory?(ssh_dir)
    kyb_dir = File.expand_path('~/.kyb')
    FileUtils.mkdir_p(kyb_dir) unless File.directory?(kyb_dir)
    args += ['-v', "#{kyb_dir}:#{kyb_dir}"]
    args += ['-v', "#{ENV['HOME']}/.kimi:/home/dev/.kimi"]
    args += ['-v', "#{ENV['HOME']}/.gitconfig:/home/dev/.gitconfig:ro"]
    args += ['-v', "#{ENV['HOME']}/.claude/settings.json:/home/dev/.claude-host-settings.json:ro"]
    skills = File.expand_path('~/.claude/skills')
    args += ['-v', "#{skills}:/home/dev/.claude-skills-host:ro"] if File.directory?(skills)
    agents = File.expand_path('~/.agents')
    args += ['-v', "#{agents}:/home/.agents:ro"] if File.directory?(agents)
    dind = File.exist?('/.dockerenv')

    args += ['-v', '/var/run/docker.sock:/var/run/docker.sock']
    args += ['-v', "#{container.claude_volume}:/home/dev/.claude"]
    if dind
      # Docker-in-Docker: bind-mounting container-local paths fails because
      # host Docker daemon can't see the path. Use a named volume instead,
      # then copy the worktree into it after container starts.
      args += ['-v', "#{container.name}-worktree:/home/dev/projects/#{project_name}"]
    else
      args += ['-v', "#{wt_path}:/home/dev/projects/#{project_name}"]
    end
    args += ['-v', "#{container.node_modules_volume}:/home/dev/projects/#{project_name}/node_modules"]
    unless project_path == "/home/dev/projects/#{project_name}"
      args += ['-v', "#{project_path}:#{project_path}"]
    end

    symlinks.to_s.split(',').each do |link|
      next if link.empty?
      args += ['-v', "#{project_path}/#{link}:/home/dev/projects/#{project_name}/#{link}:ro"]
    end

    mounts_rw.to_s.split(',').each do |m|
      next if m.empty?
      host_path, container_path = m.split(':', 2)
      next unless host_path && container_path
      args += ['-v', "#{File.expand_path(host_path)}:#{container_path}"]
    end

    mounts_ro.to_s.split(',').each do |m|
      next if m.empty?
      host_path, container_path = m.split(':', 2)
      next unless host_path && container_path
      args += ['-v', "#{File.expand_path(host_path)}:#{container_path}:ro"]
    end

    # Mount host build-tool caches so dependencies survive container recreation
    gradle_home = File.expand_path('~/.gradle')
    if File.exist?(File.join(wt_path, 'gradlew')) || File.directory?(File.join(wt_path, 'gradle'))
      FileUtils.mkdir_p(gradle_home)
      args += ['-v', "#{gradle_home}:/home/dev/.gradle"]
    end

    ports.to_s.split(',').each do |p|
      next if p.empty?
      args += ['-p', p]
    end

    args << image

    system(*args) || Kyb.die('docker run failed')
  end

  def stop(container)
    puts "==> Stopping #{container}"
    system('docker', 'stop', container)
    puts "==> Done: #{container} stopped"
  end

  def start_existing(container)
    if running?(container)
      puts "==> #{container} is already running"
      return
    end
    puts "==> Starting #{container}"
    system('docker', 'start', container)
    puts "==> Done: #{container} started"
  end

  def create_container(project, branch, port_overrides = nil, model: nil)
    Kyb::Config.load

    if %w[master main].include?(branch)
      Kyb.die("creating containers for '#{branch}' branch is not allowed.\n  Use a feature branch instead: kyb create #{project}-<branch-name>")
    end

    proj = Kyb::Config.project(project)
    path = proj[:path]
    base = Kyb::Config.base_image_path

    container = Kyb::Container.new(project, branch)

    if container.exists?
      Kyb.die("container '#{container.name}' already exists.\n  Remove it first: kyb rm #{project}-#{branch}")
    end

    ports = port_overrides || assign_ports(proj[:ports])

    build(Kyb::Container::BASE_IMAGE, base)

    image = Kyb::Container::BASE_IMAGE

    wt_path = container.worktree_path
    Kyb::Git.setup_worktree(path, proj[:base_branch], wt_path, container)

    if proj[:env_template] && !proj[:env_template].empty?
      src = File.join(path, proj[:env_template])
      dst = File.join(wt_path, '.env')
      puts "     cp #{src} -> .env"
      FileUtils.cp(src, dst)
    end

    if proj[:dockerfile]
      df_path = File.join(path, proj[:dockerfile])
      image = project_image(project, df_path, path)
    end

    FileUtils.mkdir_p(File.expand_path('~/.kimi'))

    run(
      container: container,
      image: image,
      wt_path: wt_path,
      project_name: project,
      project_path: path,
      ports: ports,
      symlinks: proj[:symlinks],
      mounts_rw: proj[:mounts_rw],
      mounts_ro: proj[:mounts_ro],
      model: model,
      timezone: proj[:timezone],
      kyb_proxy: proj[:proxy],
      kyb_no_proxy: proj[:no_proxy]
    )

    60.times do
      break if system('docker', 'exec', '-u', 'dev', container.name,
                      'test', '-f', '/home/dev/.claude/settings.json',
                      out: File::NULL, err: File::NULL)
      sleep 0.5
    end

    if File.exist?('/.dockerenv')
      puts "==> #{container.name}: copying worktree into container"
      system('docker', 'cp', "#{wt_path}/.", "#{container.name}:/home/dev/projects/#{project}/")
    end

    [container.name, ports]
  end
end
