# frozen_string_literal: true

module Kyb::CLI
  DID_PREFIX = 'did-'

  module_function

  def did(argv)
    cmd = argv.first
    args = argv[1..] || []

    case cmd
    when 'create'
      Kyb.die("Usage: kyb did create <name>") unless args.first
      did_create(args)
    when 'rm'
      Kyb.die("Usage: kyb did rm <name>") unless args.first
      did_rm(args)
    when 'ps', 'ls'
      did_ps
    else
      did_help
    end
  end

  # Determine the parent container name for label/ENV.
  # When run inside a kyb container, KYB_PARENT is set explicitly.
  # When run inside a DinD container (KYB_PROJECT set but no KYB_PARENT),
  # fall back to the container hostname.
  # When run on the host, returns nil — caller defaults to 'host'.
  def did_parent_name
    ENV['KYB_PARENT'] || (ENV['KYB_PROJECT'] && `hostname`.strip) rescue nil
  end

  # After mounting kyb-swift-cache volume, add Swift to PATH in .bashrc
  # so non-interactive shells (docker exec) can find swift immediately.
  def fix_did_swift_path(cname)
    swift_bin = '/home/dev/.local/swift/usr/bin/swift'
    return unless system('docker', 'exec', '-u', 'dev', cname,
                         'test', '-f', swift_bin, out: File::NULL, err: File::NULL)
    system('docker', 'exec', '-u', 'dev', cname,
           'sed', '-i',
           '/^\\[ -z "\\$PS1" \\]/iexport PATH=/home/dev/.local/swift/usr/bin:$PATH',
           '/home/dev/.bashrc')
  end

  def did_create(args)
    name = args.first
    cname = "#{DID_PREFIX}#{name}"
    Kyb.die("container '#{cname}' already exists") if Kyb::Docker.exists?(cname)

    parent = did_parent_name || 'host'
    volume = "#{cname}-worktree"

    system('docker', 'volume', 'create', volume) || Kyb.die("failed to create volume '#{volume}'")

    run_args = %w[docker run -d --name]
    run_args << cname
    run_args += ['--label', 'kyb=true']
    run_args += ['--label', "kyb-did=#{parent}"]
    run_args += ['-e', "KYB_PROJECT=#{name}"]
    run_args += ['-e', "KYB_PARENT=#{parent}"]
    run_args += ['-e', "GITLAB_TOKEN=#{ENV['GITLAB_TOKEN']}"] if ENV['GITLAB_TOKEN']
    run_args += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"] if ENV['KIMI_API_KEY']
    run_args += ['-e', "ALL_PROXY=#{Kyb::Config.proxy}"] if Kyb::Config.proxy
    run_args += ['-e', "NO_PROXY=#{Kyb::Config.no_proxy}"] if Kyb::Config.no_proxy
    run_args += ['-v', "#{volume}:/home/dev/projects/#{name}"]

    # Shared build-tool caches
    %w[kyb-gradle-cache kyb-maven-cache kyb-mise-cache kyb-pip-cache].each do |vol|
      system('docker', 'volume', 'create', vol, out: File::NULL) || Kyb.die("failed to create volume '#{vol}'")
    end
    run_args += ['-v', 'kyb-gradle-cache:/home/dev/.gradle']
    run_args += ['-v', 'kyb-maven-cache:/home/dev/.m2/repository']
    run_args += ['-v', 'kyb-mise-cache:/home/dev/.local/share/mise/downloads']
    run_args += ['-v', 'kyb-pip-cache:/home/dev/.cache/pip']

    # Mount Swift toolchain cache if available
    swift_cache = 'kyb-swift-cache'
    swift_mounted = false
    if `docker volume ls -q --filter name=^#{swift_cache}$`.strip == swift_cache
      run_args += ['-v', "#{swift_cache}:/home/dev/.local/swift"]
      swift_mounted = true
    end

    run_args += ['-v', '/var/run/docker.sock:/var/run/docker.sock']
    run_args += ['--hostname', cname]
    run_args << Kyb::Container::BASE_IMAGE

    puts "==> #{cname}: creating DID container (parent: #{parent})"
    system(*run_args) || Kyb.die('docker run failed')

    # Wait for container to be ready (settings.json check)
    30.times do
      break if system('docker', 'exec', '-u', 'dev', cname,
                       'test', '-f', '/home/dev/.claude/settings.json',
                       out: File::NULL, err: File::NULL)
      sleep 0.5
    end

    # Configure mise to keep downloaded archives (shared cache volume)
    system('docker', 'exec', '-u', 'dev', cname,
           'bash', '-l', '-c', 'mise settings set always_keep_downloads true 2>/dev/null || true')

    # Copy SSH keys into container (bind mount doesn't work in DinD)
    ssh_dir = File.expand_path('~/.ssh')
    if File.directory?(ssh_dir)
      system('docker', 'cp', "#{ssh_dir}/.", "#{cname}:/home/dev/.ssh/")
    end

    # Copy gitconfig
    gitconfig = File.expand_path('~/.gitconfig')
    if File.exist?(gitconfig) && !File.directory?(gitconfig)
      system('docker', 'cp', gitconfig, "#{cname}:/home/dev/.gitconfig")
    end

    # Copy kyb config so container can discover other projects
    kyb_config = File.expand_path('~/.config/kyb')
    if File.directory?(kyb_config)
      system('docker', 'cp', "#{kyb_config}/.", "#{cname}:/home/dev/.config/kyb/")
    end

    # Fix ownership of copied files (docker cp preserves root ownership)
    system('docker', 'exec', '-u', 'root', cname,
           'chown', '-R', 'dev:dev', '/home/dev/.ssh', '/home/dev/.gitconfig', '/home/dev/.config')

    # Auto-configure Swift PATH if swift cache volume was mounted
    fix_did_swift_path(cname) if swift_mounted

    puts
    puts "==> ／人◕ ‿‿ ◕人＼ DID container ready! Container: #{cname}"
  end

  def did_rm(args)
    name = args.first
    cname = "#{DID_PREFIX}#{name}"

    # Remove child containers (DID-in-DID nesting)
    `docker ps -a --format '{{.Names}}' --filter label=kyb-did=#{cname}`.lines.map(&:strip).each do |child|
      puts "==> #{child}: removing child container"
      system('docker', 'rm', '-f', child)
    end

    Kyb::Docker.remove_container(cname)
    Kyb::Docker.volume_rm("#{cname}-worktree")

    puts "==> Done: #{cname} removed"
  end

  def did_ps
    list = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter 'name=did-' 2>/dev/null`
            .lines.map { |l| l.strip.split("\t", 3) }

    if list.empty?
      puts 'No DID containers.'
      return
    end

    printf "%-24s  %-24s  %s\n", 'DID NAME', 'STATUS', 'PORTS'
    list.each do |name, status, ports|
      label = `docker inspect --format '{{index .Config.Labels "kyb-did"}}' #{name}`.strip rescue ''
      parent = label.empty? ? '' : "parent: #{label}"
      printf "%-24s  %-24s  %s\n", name.sub(/^did-/, ''), status, parent
    end
  end

  def did_help
    puts <<~HELP
      kyb did — Docker-in-Docker containers

      Usage: kyb did COMMAND

      Commands:
        create <name>    Create a DID container
        rm <name>        Remove a DID container (and its children)
        ps, ls           List DID containers
    HELP
  end
end
