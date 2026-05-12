# frozen_string_literal: true

module Kyb::Docker
  module_function

  def build(tag, path)
    puts "==> Building base image: #{tag}"
    system('docker', 'build', '-t', tag, path.to_s) || Kyb.die('docker build failed')
  end

  def project_image(name, dockerfile, context)
    image = "dev-#{name}"
    puts "==> #{name}: building project image (#{dockerfile})"
    system('docker', 'build', '-t', image, '-f', dockerfile.to_s, context.to_s) || Kyb.die('docker build failed')
    image
  end

  def container_name(name, suffix = nil)
    suffix ? "dev-#{name}-#{suffix}" : "dev-#{name}"
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
    out = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter 'name=dev-' 2>/dev/null`
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
    out = `docker ps -a --format '{{.Names}}' --filter 'name=dev-#{name}' 2>/dev/null`
    out.lines.map(&:strip).reject(&:empty?)
  end

  def run(container:, image:, hostname:, wt_path:, project_name:, project_path:, ports:, symlinks:)
    puts "==> #{container}: starting (#{wt_path} -> /home/dev/projects/#{project_name})"

    args = %w[docker run -d]
    args += ['--name', container]
    args += ['--hostname', hostname]
    args += ['-e', "HOST_UID=#{Process.uid}"]
    args += ['-e', "HOST_GID=#{Process.gid}"]
    args += ['-e', "GITLAB_TOKEN=#{ENV['GITLAB_TOKEN']}"]
    args += ['-e', "CLAUDE_CODE_ATTRIBUTION_HEADER=#{ENV['CLAUDE_CODE_ATTRIBUTION_HEADER']}"]
    args += ['-e', "CLAUDE_CODE_EFFORT_LEVEL=#{ENV['CLAUDE_CODE_EFFORT_LEVEL']}"]
    args += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"]
    args += ['-e', "SANDBOX_PROJECT=#{project_name}"]

    ssh_dir = File.expand_path('~/.ssh')
    args += ['-v', "#{ssh_dir}:/home/dev/.ssh:ro"] if File.directory?(ssh_dir)
    args += ['-v', "#{ENV['HOME']}/.kimi:/home/dev/.kimi"]
    args += ['-v', "#{ENV['HOME']}/.gitconfig:/home/dev/.gitconfig:ro"]
    args += ['-v', "#{ENV['HOME']}/.claude/settings.json:/home/dev/.claude-host-settings.json:ro"]
    skills = File.expand_path('~/.claude/skills')
    args += ['-v', "#{skills}:/home/dev/.claude-skills-host:ro"] if File.directory?(skills)
    agents = File.expand_path('~/.agents')
    args += ['-v', "#{agents}:/home/.agents:ro"] if File.directory?(agents)
    args += ['-v', '/var/run/docker.sock:/var/run/docker.sock']
    args += ['-v', "#{container}-claude:/home/dev/.claude"]
    args += ['-v', "#{wt_path}:/home/dev/projects/#{project_name}"]
    args += ['-v', "#{project_name}-node_modules:/home/dev/projects/#{project_name}/node_modules"]
    args += ['-v', "#{project_path}:#{project_path}"]

    symlinks.to_s.split(',').each do |link|
      next if link.empty?
      args += ['-v', "#{project_path}/#{link}:/home/dev/projects/#{project_name}/#{link}:ro"]
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

  def run_play(container:, image:)
    puts "==> #{container}: starting magic sandbox"

    args = %w[docker run -d]
    args += ['--name', container]
    args += ['--hostname', container]
    args += ['-e', "HOST_UID=#{Process.uid}"]
    args += ['-e', "HOST_GID=#{Process.gid}"]
    args += ['-e', "GITLAB_TOKEN=#{ENV['GITLAB_TOKEN']}"]
    args += ['-e', "CLAUDE_CODE_ATTRIBUTION_HEADER=#{ENV['CLAUDE_CODE_ATTRIBUTION_HEADER']}"]
    args += ['-e', "CLAUDE_CODE_EFFORT_LEVEL=#{ENV['CLAUDE_CODE_EFFORT_LEVEL']}"]
    args += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"]

    ssh_dir = File.expand_path('~/.ssh')
    args += ['-v', "#{ssh_dir}:/home/dev/.ssh:ro"] if File.directory?(ssh_dir)
    args += ['-v', "#{ENV['HOME']}/.kimi:/home/dev/.kimi"]
    args += ['-v', "#{ENV['HOME']}/.gitconfig:/home/dev/.gitconfig:ro"]
    args += ['-v', "#{ENV['HOME']}/.claude/settings.json:/home/dev/.claude-host-settings.json:ro"]
    skills = File.expand_path('~/.claude/skills')
    args += ['-v', "#{skills}:/home/dev/.claude-skills-host:ro"] if File.directory?(skills)
    agents = File.expand_path('~/.agents')
    args += ['-v', "#{agents}:/home/.agents:ro"] if File.directory?(agents)
    args += ['-v', '/var/run/docker.sock:/var/run/docker.sock']
    args += ['-v', "#{container}-claude:/home/dev/.claude"]
    args += ['-v', "#{container}-home:/home/dev"]

    args << image

    system(*args) || Kyb.die('docker run failed')
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

  def create_container(name, suffix = nil, port_overrides = nil)
    Kyb::Config.load
    proj = Kyb::Config.project(name)
    path = proj[:path]
    base = Kyb::Config.base_image_path

    container = container_name(name, suffix)

    if exists?(container)
      Kyb.die("container '#{container}' already exists.\n  Remove it first: kyb rm #{name}#{suffix ? " #{suffix}" : ''}")
    end

    ports = port_overrides || assign_ports(proj[:ports])

    build(Kyb::BASE_IMAGE, base)

    image = Kyb::BASE_IMAGE

    wt_path = Kyb::Git.worktree_path(name, container)
    Kyb::Git.setup_worktree(path, proj[:base_branch], wt_path, container)

    if proj[:env_template] && !proj[:env_template].empty?
      src = File.join(path, proj[:env_template])
      dst = File.join(wt_path, '.env')
      puts "     cp #{src} -> .env"
      FileUtils.cp(src, dst)
    end

    if proj[:dockerfile]
      df_path = File.join(path, proj[:dockerfile])
      image = project_image(name, df_path, path)
    end

    FileUtils.mkdir_p(File.expand_path('~/.kimi'))

    run(
      container: container,
      image: image,
      hostname: container,
      wt_path: wt_path,
      project_name: name,
      project_path: path,
      ports: ports,
      symlinks: proj[:symlinks]
    )

    60.times do
      break if system('docker', 'exec', '-u', 'dev', container,
                      'test', '-f', '/home/dev/.claude/settings.json',
                      out: File::NULL, err: File::NULL)
      sleep 0.5
    end

    [container, ports]
  end
end
