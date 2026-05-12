# frozen_string_literal: true

module Kyb::CLI
  module_function

  def ps
    list = Kyb::Docker.ps_list
    if list.empty?
      puts "(◕‿‿◕) No sandbox containers — create one with: kyb create <name>"
      return
    end
    printf "%-30s  %-24s  %s\n", 'CONTAINER', 'STATUS', 'PORTS'
    list.each { |name, status, ports| printf "%-30s  %-24s  %s\n", name, status, ports }
  end
  singleton_class.alias_method :ls, :ps

  def exec_cmd(name, args)
    suffix = nil
    if args.first && args.first != '--'
      suffix = args.shift
    end
    args.shift if args.first == '--'
    Kyb.die('exec requires a command') if args.empty?

    container = Kyb::Docker.container_name(name, suffix)
    Kyb.die("container '#{container}' is not running") unless Kyb::Docker.running?(container)

    exec('docker', 'exec', '-it', '-u', 'dev', '-w', "/home/dev/projects/#{name}", container, *args)
  end

  def stop(name, suffix = nil)
    Kyb.die('stop requires a project name') unless name
    container = Kyb::Docker.container_name(name, suffix)
    Kyb.die("container '#{container}' is not running") unless Kyb::Docker.running?(container)
    Kyb::Docker.stop(container)
  end

  def start(name, suffix = nil)
    Kyb.die('start requires a project name') unless name
    container = Kyb::Docker.container_name(name, suffix)
    Kyb.die("container '#{container}' does not exist\n  Run: kyb create #{name}#{" #{suffix}" if suffix}") unless Kyb::Docker.exists?(container)
    Kyb::Docker.start_existing(container)
  end

  def rm(name, suffix = nil)
    Kyb.die("rm requires a project name\n  Usage: kyb rm NAME [SUFFIX]") unless name

    if name == 'play'
      container = 'dev-play'
      Kyb::Docker.remove_container(container)
      Kyb::Docker.volume_rm("#{container}-claude")
      Kyb::Docker.volume_rm("#{container}-home")
      puts "==> Done: #{container} removed  (◕‿‿◕)"
      return
    end

    Kyb::Config.load
    proj = Kyb::Config.project(name)
    path = proj[:path]
    Kyb.die("#{path} not found") unless File.directory?(path)

    container = Kyb::Docker.container_name(name, suffix)
    Kyb::Docker.remove_container(container)

    wt_path = Kyb::Git.worktree_path(name, container)
    Kyb::Git.remove_worktree(path, wt_path)
    Kyb::Git.delete_local_branch(path, container)
    Kyb::Git.delete_remote_branch(path, container)

    Kyb::Docker.volume_rm("#{container}-claude")

    puts "==> Done: #{container} removed  (◕‿‿◕)"
  end

  def prune
    Kyb::Config.load
    Kyb::Config.project_names.each do |proj_name|
      proj = Kyb::Config.project(proj_name)
      path = proj[:path]
      unless File.directory?(path)
        warn "WARNING: #{path} not found, skip #{proj_name}"
        next
      end

      Kyb::Docker.containers_for_project(proj_name).each do |c|
        puts "==> #{c}: removing container"
        system('docker', 'rm', '-f', c)

        wt_path = Kyb::Git.worktree_path(proj_name, c)
        Kyb::Git.remove_worktree(path, wt_path)
        Kyb::Git.delete_local_branch(path, c)
        Kyb::Git.delete_remote_branch(path, c)

        Kyb::Docker.volume_rm("#{c}-claude")
        puts
      end
    end

    puts "==> All sandboxes cleaned  (◕‿‿◕)"
  end
end
