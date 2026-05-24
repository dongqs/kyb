# frozen_string_literal: true

module Kyb::CLI
  def did(argv)
    show_all = argv.delete('--all') || argv.delete('-a')
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
      did_ps(show_all: show_all)
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
  # so login shells (docker exec bash -l -c) can find swift immediately.
  def fix_did_swift_path(cname)
    swift_bin = '/home/dev/.local/swift/usr/bin/swift'
    return unless system('docker', 'exec', '-u', 'dev', cname,
                         'test', '-f', swift_bin, out: File::NULL, err: File::NULL)
    system('docker', 'exec', '-u', 'dev', cname,
           'sed', '-i',
           '/^case \\$- in/iexport PATH=/home/dev/.local/swift/usr/bin:$PATH',
           '/home/dev/.bashrc')
  end

  def did_create(args)
    Kyb.die("DID nesting is not allowed (already inside a DID container)") if ENV['KYB_DID']
    project = ENV['KYB_PROJECT']
    branch  = ENV['KYB_BRANCH']
    Kyb.die("kyb did create must run inside a kyb container (KYB_PROJECT and KYB_BRANCH required)") unless project && branch

    cpus = nil
    rest = args.dup
    if (idx = rest.index('--cpus'))
      rest.delete_at(idx)
      cpus = rest.delete_at(idx)
      Kyb.die("--cpus requires a positive number, got: #{cpus.inspect}") unless cpus.to_f.positive?
    end

    name = rest.first
    safe_branch = branch.gsub(/[^a-zA-Z0-9_.-]/, '-')
    cname = "did-#{project}-#{safe_branch}-#{name}"

    all_names = `docker ps -a --format '{{.Names}}'`.lines.map(&:strip)
    Kyb.die("container '#{cname}' already exists") if all_names.include?(cname)

    parent = did_parent_name || 'host'
    volume = "#{cname}-worktree"

    Kyb::Docker.ensure_volume(volume) || Kyb.die("failed to create volume '#{volume}'")

    run_args = %w[docker run -d --init --restart on-failure:5 --name]
    run_args << cname
    run_args += ['--label', 'kyb=true']
    run_args += ['--label', "did_parent=#{parent}"]
    run_args += ['-e', "KYB_PROJECT=#{name}"]
    run_args += ['-e', "KYB_BRANCH=#{branch}"]
    run_args += ['-e', "KYB_PARENT=#{parent}"]
    run_args += ['-e', "KYB_DID=#{name}"]
    run_args += ['-e', "GITLAB_TOKEN=#{ENV['GITLAB_TOKEN']}"] if ENV['GITLAB_TOKEN']
    run_args += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"] if ENV['KIMI_API_KEY']
    if Kyb::Config.proxy
      proxy_translated = Kyb::Docker.host_to_docker_proxy(Kyb::Config.proxy)
      run_args += ['-e', "ALL_PROXY=#{proxy_translated}"]
    end
    run_args += ['-e', "NO_PROXY=#{Kyb::Config.no_proxy}"]
    run_args += ['-v', "#{volume}:/home/dev/projects/#{name}"]

    # Shared build-tool caches
    %w[kyb-gradle-cache kyb-maven-cache kyb-mise-cache kyb-pip-cache].each do |vol|
      Kyb::Docker.ensure_volume(vol) || Kyb.die("failed to create volume '#{vol}'")
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
    run_args += ['--cpus', cpus.to_s] if cpus
    run_args << Kyb::Container::BASE_IMAGE

    puts "==> #{cname}: creating DID container (parent: #{parent})"
    system(*run_args) || Kyb.die('docker run failed')

    # Wait for container to be ready (kyb-ready sentinel from entrypoint)
    60.times do
      break if system('docker', 'exec', '-u', 'dev', cname,
                       'test', '-f', '/tmp/kyb-ready',
                       out: File::NULL, err: File::NULL)
      sleep 0.5
    end

    # Copy host config files into container via tar pipe (single API round-trip)
    home = Dir.home
    tar_sources = []
    tar_sources << '.ssh' if File.directory?("#{home}/.ssh")
    tar_sources << '.gitconfig' if File.exist?("#{home}/.gitconfig")
    tar_sources << '.config/kyb' if File.directory?("#{home}/.config/kyb")

    if tar_sources.any?
      system('bash', '-c',
        "tar -C #{home} --exclude='.ssh/agent/*' -c #{tar_sources.join(' ')} 2>/dev/null | " \
        "docker exec -i #{cname} bash -c '" \
        "tar -C /home/dev -x " \
        "&& chown -R dev:dev #{tar_sources.map { |s| "/home/dev/#{s}" }.join(' ')} 2>/dev/null || true'")
    end

    # Auto-configure Swift PATH if swift cache volume was mounted
    fix_did_swift_path(cname) if swift_mounted

    puts
    puts "==> ／人◕ ‿‿ ◕人＼ DID container ready! Container: #{cname}"
  end

  def did_rm(args)
    name = args.first
    candidates = `docker ps -a --format '{{.Names}}' --filter name=did-`.lines.map(&:strip).select { |n| n.end_with?("-#{name}") }
    if candidates.empty?
      puts "==> No DID container found matching '#{name}'"
      return
    end
    if candidates.size > 1
      warn "WARNING: multiple containers match '#{name}', using first: #{candidates.first}"
    end
    cname = candidates.first

    # Remove child containers (DID-in-DID nesting)
    Kyb::Docker.did_children(cname).each do |child|
      puts "==> #{child}: removing child container"
      system('docker', 'rm', '-f', child)
    end

    Kyb::Docker.remove_container(cname)
    Kyb::Docker.volume_rm("#{cname}-worktree")

    puts "==> Done: #{cname} removed"
  end

  def did_ps(show_all: false)
    # Determine filter base
    if show_all
      list = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter 'name=did-' 2>/dev/null`
              .lines.map { |l| l.strip.split("\t", 3) }
    elsif ENV['KYB_DID']
      # Inside a DID container — show siblings (same parent)
      parent = ENV['KYB_PARENT']
      list = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter label=did_parent=#{parent} 2>/dev/null`
              .lines.map { |l| l.strip.split("\t", 3) }
    elsif ENV['KYB_PROJECT']
      # Inside a regular kyb container — show children
      my_name = `hostname`.strip
      list = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter label=did_parent=#{my_name} 2>/dev/null`
              .lines.map { |l| l.strip.split("\t", 3) }
    else
      # On host — show all
      list = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter 'name=did-' 2>/dev/null`
              .lines.map { |l| l.strip.split("\t", 3) }
    end

    if list.empty?
      puts 'No DID containers.'
      return
    end

    printf "%-24s  %-24s  %s\n", 'DID NAME', 'STATUS', 'PARENT'
    list.each do |name, status, ports|
      label = `docker inspect --format '{{index .Config.Labels "did_parent"}}' #{name}`.strip rescue ''
      parent = label.empty? ? '' : "parent: #{label}"
      printf "%-24s  %-24s  %s\n", name.sub(/^did-/, ''), status, parent
    end
  end

  def did_help
    puts <<~HELP
      kyb did — Docker-in-Docker containers

      Usage: kyb did COMMAND

      Commands:
        create <name> [--cpus N]    Create a DID container (--cpus: limit CPU cores)
        rm <name>        Remove a DID container (and its children)
        ps, ls [--all]   List DID containers (--all: show all, default: siblings)
    HELP
  end

  module_function :did, :did_create, :did_rm, :did_ps, :did_help, :fix_did_swift_path
end
