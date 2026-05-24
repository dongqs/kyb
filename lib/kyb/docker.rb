# frozen_string_literal: true

require 'digest'

module Kyb::Docker
  module_function

  BUILD_HASH_FILES = %w[Dockerfile entrypoint.sh].freeze

  def build(tag, path, proxy: nil)
    puts "==> Building base image: #{tag}"
    env = { 'DOCKER_BUILDKIT' => '1' }
    build_hash = compute_build_hash(path)
    args = ['docker', 'build', '-t', tag, '--label']
    args << "kyb.build-hash=#{build_hash}"
    if proxy
      build_proxy = host_to_docker_proxy(proxy)
      puts "  [PROXY] #{proxy}"
      puts "  [BUILD PROXY] #{build_proxy}" if build_proxy != proxy
      args += ['--build-arg', "BUILD_ALL_PROXY=#{build_proxy}"]
    else
      puts '  [PROXY] none (direct connections)'
    end
    args << path.to_s
    system(env, *args) || Kyb.die('docker build failed')
  end

  # Replace 127.0.0.1/localhost with host.docker.internal so proxy
  # works inside Docker build containers (where 127.0.0.1 is the
  # container itself, not the host).
  def host_to_docker_proxy(proxy)
    proxy.sub(/\A(socks5|http|https):\/\/(127\.0\.0\.1|localhost)(:\d+)/) { "#{$1}://host.docker.internal#{$3}" }
  end

  def image_exists?(image)
    `docker images -q #{image}`.strip.length.positive?
  end

  # Compare SHA256 hash of Dockerfile + entrypoint.sh against the label stored
  # on the image at build time. Returns true if source files have changed.
  # Does NOT run a full docker build (unlike the old approach which could hang).
  def stale?(tag, path)
    image_hash = `docker inspect --format='{{index .Config.Labels "kyb.build-hash"}}' #{tag} 2>/dev/null`.strip
    return false if image_hash.empty?
    compute_build_hash(path) != image_hash
  rescue => e
    warn "stale check failed: #{e.message}"
    false
  end

  def compute_build_hash(path)
    hasher = Digest::SHA256.new
    BUILD_HASH_FILES.each do |f|
      file = File.join(path, f)
      hasher.update(File.read(file)) if File.exist?(file)
    end
    hasher.hexdigest
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

  def ensure_master_synced(repo_path, base_branch)
    return unless File.directory?("#{repo_path}/.git")
    Dir.chdir(repo_path) do
      # Fetch latest origin — safe, no local state affected
      system('git', 'fetch', 'origin', base_branch, %i[out err] => File::NULL) || return

      # Fast-forward merge from origin if possible (safe, no local changes lost)
      current = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
      if current == base_branch
        system('git', 'merge', '--ff-only', "origin/#{base_branch}", %i[out err] => File::NULL)
        return
      end

      # Switching branches — only proceed if working tree is clean
      status = `git status --porcelain 2>/dev/null`.strip
      if status.empty?
        puts "==> syncing #{repo_path} to origin/#{base_branch}"
        system('git', 'checkout', base_branch, %i[out err] => File::NULL) || return
        system('git', 'merge', '--ff-only', "origin/#{base_branch}", %i[out err] => File::NULL)
      else
        puts "==> #{repo_path}: uncommitted changes found, skipping branch sync"
      end
    end
  end

  def clone_path(project, container)
    File.join(Kyb::CLONE_BASE, project, container.name)
  end

  def setup_clone(source_path, clone_target, project, container)
    puts "==> cloning #{source_path} -> #{clone_target}"
    FileUtils.mkdir_p(File.dirname(clone_target))
    system('git', 'clone', source_path, clone_target) || Kyb.die('git clone failed')
  end

  def check_shared_project_conflict(project)
    containers_for_project(project).select { |name| running?(name) }
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

  # ── run ──────────────────────────────────────────────────────────────

  def run(container:, image:, repo_path:, project_name:, project_path:, ports:, symlinks:, mounts_rw:, mounts_ro:, model: nil, timezone: 'Asia/Shanghai', kyb_proxy: nil, kyb_no_proxy: nil, branch: nil, clone: false, memory: nil)
    puts "==> #{container.name}: starting (#{repo_path} -> /home/dev/projects/#{project_name})"

    args = build_run_args(
      container: container, image: image, repo_path: repo_path,
      project_name: project_name, project_path: project_path,
      ports: ports, symlinks: symlinks, mounts_rw: mounts_rw, mounts_ro: mounts_ro,
      model: model, timezone: timezone,
      kyb_proxy: kyb_proxy, kyb_no_proxy: kyb_no_proxy,
      branch: branch, clone: clone, memory: memory
    )

    system(*args) || Kyb.die('docker run failed')
  end

  def build_run_args(container:, image:, repo_path:, project_name:, project_path:, ports:, symlinks:, mounts_rw:, mounts_ro:, model: nil, timezone: 'Asia/Shanghai', kyb_proxy: nil, kyb_no_proxy: nil, branch: nil, clone: false, memory: nil)
    args = %w[docker run -d --init --restart on-failure:5]
    args += ['--name', container.name]
    args += ['--hostname', container.hostname]
    args += build_network_args
    memory_value = memory || Kyb::Config.default_memory
    args += ['--memory', memory_value, '--memory-swap', memory_value]
    args += build_env_args(
      project_name: project_name, model: model, timezone: timezone,
      kyb_proxy: kyb_proxy, kyb_no_proxy: kyb_no_proxy, branch: branch
    )
    args += ['-l', Kyb::Container::LABEL]
    args += build_volume_args(
      container: container, repo_path: repo_path,
      project_name: project_name, project_path: project_path,
      symlinks: symlinks, mounts_rw: mounts_rw, mounts_ro: mounts_ro, clone: clone
    )

    ports.to_s.split(',').each do |p|
      next if p.empty?
      args += ['-p', p]
    end

    args << image
    args
  end

  def build_network_args
    system('docker', 'network', 'create', 'kyb-net', out: File::NULL, err: File::NULL) || true
    ['--network', 'kyb-net']
  end

  def build_env_args(project_name:, model:, timezone:, kyb_proxy:, kyb_no_proxy:, branch:)
    args = []
    args += ['-e', "HOST_UID=#{Process.uid}"]
    args += ['-e', "HOST_GID=#{Process.gid}"]
    args += ['-e', "GITLAB_TOKEN=#{ENV['GITLAB_TOKEN']}"]
    args += ['-e', "CLAUDE_CODE_ATTRIBUTION_HEADER=#{ENV['CLAUDE_CODE_ATTRIBUTION_HEADER']}"]
    args += ['-e', "CLAUDE_CODE_EFFORT_LEVEL=#{ENV['CLAUDE_CODE_EFFORT_LEVEL']}"]
    args += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"]
    args += ['-e', "KYB_PROJECT=#{project_name}"]
    args += ['-e', "KYB_MODEL=#{model || Kyb::Config.claude_default_model}"]
    args += ['-e', "TZ=#{timezone}"]
    if kyb_proxy
      kyb_proxy_translated = host_to_docker_proxy(kyb_proxy)
      args += ['-e', "KYB_PROXY=#{kyb_proxy_translated}"]
      # Also export as ALL_PROXY/HTTPS_PROXY/HTTP_PROXY so docker exec inherits them
      # (entrypoint.sh export only affects pid 1, not docker exec processes)
      args += ['-e', "ALL_PROXY=#{kyb_proxy_translated}"]
      args += ['-e', "all_proxy=#{kyb_proxy_translated}"]
      args += ['-e', "HTTPS_PROXY=#{kyb_proxy_translated}"]
      args += ['-e', "https_proxy=#{kyb_proxy_translated}"]
      args += ['-e', "HTTP_PROXY=#{kyb_proxy_translated}"]
      args += ['-e', "http_proxy=#{kyb_proxy_translated}"]
      no_proxy_val = Kyb::Config.no_proxy
      args += ['-e', "NO_PROXY=#{no_proxy_val}"]
      args += ['-e', "no_proxy=#{no_proxy_val}"]
    end
    args += ['-e', "KYB_NO_PROXY=#{kyb_no_proxy}"] if kyb_no_proxy
    args += ['-e', "KYB_BRANCH=#{branch}"] if branch
    args
  end

  def build_volume_args(container:, repo_path:, project_name:, project_path:, symlinks:, mounts_rw:, mounts_ro:, clone:)
    args = []
    dind = Kyb.in_container?
    ssh_dir = File.expand_path('~/.ssh')
    # In DinD mode, host paths are invisible to the Docker daemon running inside
    # the container. Skip all host-only bind mounts to avoid creating empty
    # files that break the entrypoint.
    unless dind
      args += ['-v', "#{ssh_dir}:/home/dev/.ssh-host:ro"] if File.directory?(ssh_dir)
      kyb_dir = File.expand_path('~/.kyb')
      FileUtils.mkdir_p(kyb_dir) unless File.directory?(kyb_dir)
      args += ['-v', "#{kyb_dir}:#{kyb_dir}"]
      args += ['-v', "#{ENV['HOME']}/.kimi:/home/dev/.kimi"]
      args += ['-v', "#{ENV['HOME']}/.gitconfig:/home/dev/.gitconfig:ro"]
      args += ['-v', "#{ENV['HOME']}/.claude/settings.json:/home/dev/.claude-host-settings.json:ro"]
      kyb_config = File.expand_path('~/.config/kyb')
      args += ['-v', "#{kyb_config}:/home/dev/.config/kyb:ro"] if File.directory?(kyb_config)
      skills = File.expand_path('~/.claude/skills')
      args += ['-v', "#{skills}:/home/dev/.claude-skills-host:ro"] if File.directory?(skills)
      agents = File.expand_path('~/.agents')
      args += ['-v', "#{agents}:/home/.agents:ro"] if File.directory?(agents)
    end

    args += ['-v', '/var/run/docker.sock:/var/run/docker.sock']
    args += ['-v', "#{container.claude_volume}:/home/dev/.claude"]
    if dind
      args += ['-v', "#{container.name}-project:/home/dev/projects/#{project_name}"]
    else
      args += ['-v', "#{repo_path}:/home/dev/projects/#{project_name}"]
    end
    args += ['-v', "#{container.node_modules_volume}:/home/dev/projects/#{project_name}/node_modules"]
    unless dind
      unless project_path == "/home/dev/projects/#{project_name}"
        if clone
          ro_target = "/home/dev/ro_mounted_repos_do_not_edit_here/#{project_name}"
          args += ['-v', "#{project_path}:#{ro_target}:ro"]
        else
          args += ['-v', "#{project_path}:#{project_path}"]
        end
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
    end

    # Mount shared build-tool caches so dependencies survive container recreation.
    # Use named volumes (not host bind mounts) so they work in DinD where host
    # paths are invisible to the Docker daemon. All containers share the same
    # volumes — first container gets a cold cache, subsequent ones are hot.
    # Volumes are global (never cleaned by kyb rm/prune).
    %w[kyb-gradle-cache kyb-maven-cache kyb-mise-cache kyb-pip-cache].each do |vol|
      system('docker', 'volume', 'create', vol, out: File::NULL) || Kyb.die("failed to create volume '#{vol}'")
    end
    args += ['-v', 'kyb-gradle-cache:/home/dev/.gradle']
    args += ['-v', 'kyb-maven-cache:/home/dev/.m2/repository']
    args += ['-v', 'kyb-mise-cache:/home/dev/.local/share/mise/downloads']
    args += ['-v', 'kyb-pip-cache:/home/dev/.cache/pip']

    # Mount Swift toolchain cache if available
    swift_cache = 'kyb-swift-cache'
    if `docker volume ls -q --filter name=^#{swift_cache}$`.strip == swift_cache
      args += ['-v', "#{swift_cache}:/home/dev/.local/swift"]
    end

    # Mount kyb repo for agent to read docs (skipped in DinD — paths are host-only)
    unless dind
      kyb_repo = Kyb::Config.kyb_repo
      args += ['-v', "#{kyb_repo}:/home/dev/kyb:ro"] if kyb_repo
    end

    args
  end

  # ── create_container ─────────────────────────────────────────────────

  def create_container(project, branch, port_overrides = nil, model: nil, repo_root: nil)
    Kyb::Config.load

    if %w[master main].include?(branch)
      Kyb.die("creating containers for '#{branch}' branch is not allowed.\n  Use a feature branch instead: kyb create #{project}-<branch-name>")
    end

    proj = Kyb::Config.project(project)
    path = proj[:path]

    container = Kyb::Container.new(project, branch)

    if container.exists?
      Kyb.die("container '#{container.name}' already exists.\n  Remove it first: kyb rm #{project}-#{branch}")
    end

    ports = port_overrides || assign_ports(proj[:ports])

    unless image_exists?(Kyb::Container::BASE_IMAGE)
      Kyb.die("Base image '#{Kyb::Container::BASE_IMAGE}' not found.\n  Build it first: kyb build")
    end

    image = Kyb::Container::BASE_IMAGE

    # Determine clone vs mount based on repo_root (CLI overrides config)
    is_clone = determine_clone_mode(repo_root, proj)

    # Set up repo: clone independent copy or sync host repo
    clone_target = setup_project_repo(project, branch, is_clone, container, path, proj)

    # Build project-specific image if a Dockerfile is configured
    image = build_or_pull_image(project, path, proj) || image

    FileUtils.mkdir_p(File.expand_path('~/.kimi'))

    repo_path = is_clone ? clone_target : path
    run(
      container: container,
      image: image,
      repo_path: repo_path,
      project_name: project,
      project_path: path,
      ports: ports,
      symlinks: proj[:symlinks],
      mounts_rw: proj[:mounts_rw],
      mounts_ro: proj[:mounts_ro],
      model: model,
      timezone: proj[:timezone],
      kyb_proxy: proj[:proxy_in_container],
      kyb_no_proxy: proj[:no_proxy],
      memory: proj[:memory],
      branch: branch,
      clone: is_clone
    )

    wait_ready(container)
    post_start_setup(container, project, is_clone)

    [container.name, ports]
  end

  def determine_clone_mode(repo_root, proj)
    root_mode = repo_root || proj[:repo_root]
    root_mode == 'isolated_local_repo_clone'
  end

  def setup_project_repo(project, branch, is_clone, container, path, proj)
    clone_target = nil
    if is_clone
      clone_target = clone_path(project, container)
      setup_clone(path, clone_target, project, container)
    else
      ensure_master_synced(path, proj[:base_branch])
    end

    # cp_files only in clone mode (default mount means host already has these files)
    if is_clone && proj[:cp_files]
      base_keys = proj[:cp_files_base_keys] || [].freeze
      proj[:cp_files].each do |dst, src|
        src_path = File.join(path, src)
        if File.exist?(src_path)
          puts "     cp #{src} -> #{dst}"
          FileUtils.cp(src_path, File.join(clone_target, dst))
        elsif !base_keys.include?(dst)
          puts "     warn: #{src} not found, skipped"
        end
      end
    end

    clone_target
  end

  def build_or_pull_image(project, path, proj)
    return nil unless proj[:dockerfile]

    df_path = File.join(path, proj[:dockerfile])
    project_image(project, df_path, path)
  end

  def wait_ready(container)
    ready = false
    60.times do
      if system('docker', 'exec', '-u', 'dev', container.name,
                'test', '-f', '/tmp/kyb-ready',
                out: File::NULL, err: File::NULL)
        ready = true
        break
      end
      sleep 0.5
    end

    return if ready

    unless running?(container.name)
      logs = `docker logs #{container.name} --tail 30 2>/dev/null`.strip
      msg = "container '#{container.name}' exited immediately.\n" \
            "  Check the entrypoint for errors:\n"
      msg += logs.empty? ? "  (no logs)\n" : logs.lines.map { |l| "  | #{l}" }.join
      Kyb.die(msg)
    end
  end

  def post_start_setup(container, project, is_clone)
    # Conflict detection: warn about shared-repo containers
    unless is_clone
      same_project = check_shared_project_conflict(project) - [container.name]
      if same_project.any?
        puts
        puts "==> ⚠ 注意：项目 #{project} 已有运行中容器（#{same_project.join(', ')}）"
        puts "    多个容器共享同一 repo，git 操作可能互相影响。"
        puts "    如需隔离建议：kyb create --clone #{project}-<branch>"
      end
    end

    return unless Kyb.in_container?

    home = Dir.home
    tar_sources = []
    tar_sources << '.ssh' if File.directory?("#{home}/.ssh")
    tar_sources << '.gitconfig' if File.exist?("#{home}/.gitconfig")
    tar_sources << '.config/kyb' if File.directory?("#{home}/.config/kyb")

    return unless tar_sources.any?

    system('bash', '-c',
      "tar -C #{home} --exclude='.ssh/agent/*' -c #{tar_sources.join(' ')} 2>/dev/null | " \
      "docker exec -i #{container.name} bash -c '" \
      "tar -C /home/dev -x " \
      "&& chown -R dev:dev #{tar_sources.map { |s| "/home/dev/#{s}" }.join(' ')} 2>/dev/null || true'")
  end
end
