# frozen_string_literal: true

module Kyb::CLI
  def infra(argv)
    cmd = argv.first
    args = argv[1..] || []

    case cmd
    when 'boss'
      boss(args)
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

  BOSS_NAME = 'kyb-infra-boss'
  SING_BOX = 'kyb-infra-sing-box'

  def boss(args)
    cmd = args.first
    case cmd
    when 'up', 'create'
      boss_up
    when 'down', 'rm'
      boss_down
    when 'enter', 'ssh'
      boss_enter
    else
      boss_help
    end
  end

  def boss_up
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

    run_args = %w[docker run -d --name]
    run_args << BOSS_NAME
    run_args += ['--restart', 'unless-stopped']
    run_args += ['--label', 'kyb=true']
    run_args += ['-e', 'ALL_PROXY=socks5://kyb-infra-sing-box:2080']
    run_args += ['-e', "GITLAB_TOKEN=#{ENV['GITLAB_TOKEN']}"] if ENV['GITLAB_TOKEN']
    run_args += ['-v', '/var/run/docker.sock:/var/run/docker.sock']
    run_args += ['-v', "#{tailscale_socket}:#{tailscale_socket}"] if File.exist?(tailscale_socket)
    run_args += ['--hostname', BOSS_NAME]
    run_args << Kyb::Container::BASE_IMAGE
    run_args += ['tail', '-f', '/dev/null'] # keep alive, agent attaches later

    puts "==> #{BOSS_NAME}: creating infra-boss container"
    system(*run_args) || Kyb.die('docker run failed')

    puts "==> #{BOSS_NAME}: container ready"
    puts "    Enter: docker exec -it #{BOSS_NAME} /bin/bash"
  end

  def boss_enter
    all_names = `docker ps -a --format '{{.Names}}'`.lines.map(&:strip)
    unless all_names.include?(BOSS_NAME)
      puts "==> #{BOSS_NAME} not found. Run 'kyb infra boss up' first."
      return
    end
    exec('docker', 'exec', '-it', BOSS_NAME, 'bash', '-l')
  end

  def boss_down
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
        boss up, create       Create and start kyb-infra-boss container
        boss down, rm         Remove kyb-infra-boss container
        ps, ls                List all kyb-infra-* containers
        logs [container]      Show logs (default: kyb-infra-sing-box)
        restart [container]   Restart container (default: kyb-infra-sing-box)
    HELP
  end

  def boss_help
    puts <<~HELP
      kyb infra boss — Infrastructure boss container

      Usage: kyb infra boss COMMAND

      Commands:
        up, create    Create and start kyb-infra-boss
        down, rm      Remove kyb-infra-boss
        enter, ssh    Enter kyb-infra-boss (interactive shell)
    HELP
  end

  module_function :infra, :boss, :boss_up, :boss_down, :boss_enter,
                  :infra_ps, :infra_logs, :infra_restart,
                  :infra_help, :boss_help
end
