# frozen_string_literal: true

module Kyb::CLI
  BOSS_NAME = 'kyb-infra-boss'
  SING_BOX = 'kyb-infra-sing-box'

  def infra(argv)
    cmd = argv.first
    args = argv[1..] || []

    case cmd
    when 'up', 'create'
      infra_up
    when 'down', 'rm'
      infra_down
    when 'enter', 'ssh'
      infra_enter
    when 'ps', 'ls'
      infra_ps
    when 'logs'
      infra_logs(args.first)
    when 'restart'
      infra_restart(args.first)
    else
      infra_help
    end
  end

  def infra_up
    all_names = `docker ps -a --format '{{.Names}}'`.lines.map(&:strip)
    if all_names.include?(BOSS_NAME)
      puts "==> #{BOSS_NAME} already exists"
      status = `docker inspect --format '{{.State.Status}}' #{BOSS_NAME}`.strip
      if status == 'running'
        puts "    Status: running"
        return
      end
      puts "    Status: #{status}, starting..."
      system('docker', 'start', BOSS_NAME)
      return
    end

    tailscale_socket = '/var/run/tailscaled.socket'
    unless File.exist?(tailscale_socket)
      puts "⚠ tailscale socket not found at #{tailscale_socket}"
      puts "  Container will start without tailscale control."
    end

    args = %w[docker run -d --name]
    args << BOSS_NAME
    args += ['--hostname', BOSS_NAME]
    args += ['--restart', 'unless-stopped']
    args += ['-e', "HOST_UID=#{Process.uid}"]
    args += ['-e', "HOST_GID=#{Process.gid}"]
    args += ['-e', "GITLAB_TOKEN=#{ENV['GITLAB_TOKEN']}"] if ENV['GITLAB_TOKEN']
    args += ['-e', "ALL_PROXY=socks5://kyb-infra-sing-box:2080"]

    # Standard mounts (like kyb create)
    home = ENV['HOME']
    ssh_dir = File.expand_path('~/.ssh')
    args += ['-v', "#{ssh_dir}:/home/dev/.ssh-host:ro"] if File.directory?(ssh_dir)
    args += ['-v', "#{home}/.gitconfig:/home/dev/.gitconfig:ro"] if File.exist?("#{home}/.gitconfig")
    args += ['-v', "#{home}/.claude/settings.json:/home/dev/.claude-host-settings.json:ro"] if File.exist?("#{home}/.claude/settings.json")
    kyb_config = File.expand_path('~/.config/kyb')
    args += ['-v', "#{kyb_config}:/home/dev/.config/kyb:ro"] if File.directory?(kyb_config)
    skills = File.expand_path('~/.claude/skills')
    args += ['-v', "#{skills}:/home/dev/.claude-skills-host:ro"] if File.directory?(skills)

    # Mount kyb repo so boss can read docs and work on kyb code
    kyb_repo = File.expand_path('~/.kyb')
    args += ['-v', "#{kyb_repo}:/home/dev/kyb:ro"]
    args += ['-v', "#{kyb_repo}:/home/dev/projects/kyb"]

    # Mount the sing-box config repo for network management
    sb_config = File.expand_path('~/.config/sing-box')
    args += ['-v', "#{sb_config}:/home/dev/sing-box-config:ro"] if File.directory?(sb_config)

    # docker.sock + tailscale socket
    args += ['-v', '/var/run/docker.sock:/var/run/docker.sock']
    args += ['-v', "#{tailscale_socket}:#{tailscale_socket}"] if File.exist?(tailscale_socket)

    # Shared build caches
    %w[kyb-gradle-cache kyb-maven-cache kyb-mise-cache kyb-pip-cache].each do |vol|
      system('docker', 'volume', 'create', vol, out: File::NULL) unless `docker volume ls -q --filter name=^#{vol}$`.strip == vol
    end
    args += ['-v', 'kyb-gradle-cache:/home/dev/.gradle']
    args += ['-v', 'kyb-maven-cache:/home/dev/.m2/repository']
    args += ['-v', 'kyb-mise-cache:/home/dev/.local/share/mise/downloads']
    args += ['-v', 'kyb-pip-cache:/home/dev/.cache/pip']

    args << Kyb::Container::BASE_IMAGE

    puts "==> #{BOSS_NAME}: creating infra-boss container"
    system(*args) || Kyb.die('docker run failed')

    puts "==> #{BOSS_NAME}: container ready"
    puts "    Enter: kyb infra enter"
  end

  def infra_enter
    all_names = `docker ps -a --format '{{.Names}}'`.lines.map(&:strip)
    unless all_names.include?(BOSS_NAME)
      puts "==> #{BOSS_NAME} not found. Run 'kyb infra up' first."
      return
    end
    exec('docker', 'exec', '-it', '-u', 'dev', BOSS_NAME, 'bash', '-l')
  end

  def infra_down
    all_names = `docker ps -a --format '{{.Names}}'`.lines.map(&:strip)
    unless all_names.include?(BOSS_NAME)
      puts "==> #{BOSS_NAME} does not exist"
      return
    end
    system('docker', 'rm', '-f', BOSS_NAME)
    puts "==> #{BOSS_NAME}: removed"
  end

  def infra_ps
    list = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter 'name=kyb-infra-' 2>/dev/null`
            .lines.map { |l| l.strip.split("\t", 3) }

    if list.empty?
      puts 'No infra containers.'
      return
    end

    printf "%-28s  %-32s  %s\n", 'CONTAINER', 'STATUS', 'PORTS'
    list.each { |name, status, ports| printf "%-28s  %-32s  %s\n", name, status, ports }
  end

  def infra_logs(name = nil)
    target = name || SING_BOX
    system('docker', 'logs', '--tail', '30', target)
  end

  def infra_restart(name = nil)
    target = name || SING_BOX
    puts "==> #{target}: restarting"
    system('docker', 'restart', target)
  end

  def infra_help
    puts <<~HELP
      kyb infra — Infrastructure containers management

      Usage: kyb infra COMMAND

      Commands:
        up, create        Create and start kyb-infra-boss container
        down, rm          Remove kyb-infra-boss container
        enter, ssh        Enter kyb-infra-boss container (interactive)
        ps, ls            List all kyb-infra-* containers
        logs [container]  Show logs (default: kyb-infra-sing-box)
        restart [c]       Restart container (default: kyb-infra-sing-box)
    HELP
  end

  module_function :infra,
                  :infra_up, :infra_down, :infra_enter,
                  :infra_ps, :infra_logs, :infra_restart,
                  :infra_help
end
