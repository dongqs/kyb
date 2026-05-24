# frozen_string_literal: true

module Kyb::CLI
  module_function

  def ps
    normal = Kyb::Docker.ps_list
    did_list = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter 'name=did-' 2>/dev/null`
               .lines.map { |l| l.strip.split("\t", 3) }

    # Inside a DID container, show only sibling DID containers for display isolation.
    # When you're inside DID container A, `kyb ps` shows only other containers
    # with the same did_parent=<parent> label — not the parent itself, not unrelated ones.
    if ENV['KYB_PARENT']
      parent = ENV['KYB_PARENT']
      did_list = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter label=did_parent=#{parent} 2>/dev/null`
                 .lines.map { |l| l.strip.split("\t", 3) }
    end

    if normal.empty? && did_list.empty?
      puts "／人◕ ‿‿ ◕人＼ No containers — create one with: kyb create <project-branch>"
      return
    end

    unless did_list.empty?
      puts "DID containers:"
      printf "  %-28s  %-24s  %s\n", 'NAME', 'STATUS', 'PARENT'
      did_list.each do |name, status, ports|
        label = `docker inspect --format '{{index .Config.Labels "did_parent"}}' #{name}`.strip rescue ''
        printf "  %-28s  %-24s  %s\n", name.sub(/^did-/, ''), status, label
      end
      puts
    end

    unless normal.empty?
      printf "%-30s  %-24s  %s\n", 'PROJECT-BRANCH', 'STATUS', 'PORTS'
      normal.each { |name, status, ports| printf "%-30s  %-24s  %s\n", name.sub(/^kyb-/, ''), status, ports }
    end
  end
  singleton_class.alias_method :ls, :ps

  def exec_cmd(project, branch, args)
    Kyb.die('exec requires a command') if args.empty?

    c = Kyb::Container.new(project, branch)
    Kyb.die("container '#{c.name}' is not running") unless c.running?

    Kyb::Reporter.emit_exec(project: project, command: args.first)

    exec('docker', 'exec', '-i', '-u', 'dev', '-w', "/home/dev/projects/#{project}", c.name, *args)
  end

  def stop(project, branch)
    c = Kyb::Container.new(project, branch)
    Kyb.die("container '#{c.name}' is not running") unless c.running?
    Kyb::Docker.stop(c.name)
  end

  def start(project, branch)
    c = Kyb::Container.new(project, branch)
    Kyb.die("container '#{c.name}' does not exist\n  Run: kyb create #{project}-#{branch}") unless c.exists?
    Kyb::Docker.start_existing(c.name)
  end

  def rm(project, branch, force: false)
    Kyb::Config.load
    proj = Kyb::Config.project(project)
    path = proj[:path]
    Kyb.die("#{path} not found") unless File.directory?(path)

    c = Kyb::Container.new(project, branch)

    unless force
      is_git = File.directory?("#{path}/.git")
      dirty = false
      unpushed = false

      if is_git
        dirty = !Dir.chdir(path) { system('git', 'diff', '--quiet', %i[out err] => File::NULL) }
        unpushed = Dir.chdir(path) { `git cherry 2>/dev/null`.lines.count > 0 }
      end

      did_children = Kyb::Docker.did_children(c.name)

      if dirty || unpushed || did_children.any?
        puts "==> Pre-delete checks for #{c.name}:"
        puts "  ✗ dirty repo (uncommitted changes)" if dirty
        puts "  ✗ unpushed commits" if unpushed
        puts "  ✗ DID children: #{did_children.join(', ')}" if did_children.any?
        puts
        print "Delete anyway? [y/N] "
        ans = $stdin.gets.to_s.strip.downcase
        Kyb.die("Aborted.") unless ans == 'y'
      end
    end

    # Capture DID children info for metrics before cleanup
    had_children = Kyb::Docker.did_children(c.name).any?
    Kyb::Reporter.emit_container_rm(project: project, had_did_children: had_children)

    # Clean up any DID children first (cascade: children → parent)
    # DID containers are labeled did_parent=<parent-container>, so without
    # this cascade the parent volume would be removed while children still
    # reference parent-owned networks.
    Kyb::Docker.did_children(c.name).each do |did_child|
      puts "==> #{did_child}: removing DID child container"
      system('docker', 'rm', '-f', did_child)
      system('docker', 'volume', 'rm', "#{did_child}-project", out: File::NULL)
    end

    Kyb::Docker.remove_container(c.name)

    Kyb::Docker.volume_rm(c.claude_volume)

    clone_target = Kyb::Docker.clone_path(project, c) rescue nil
    if clone_target && File.directory?(clone_target)
      puts "==> removing clone #{clone_target}"
      FileUtils.rm_rf(clone_target)
    end

    puts "==> Done: #{c.name} removed"
    puts "==> 远端分支 #{c.git_branch} 未删除，如需清理请手动 git push origin --delete #{c.git_branch}"
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

      Kyb::Docker.containers_for_project(proj_name).each do |cname|
        c = Kyb::Container.new(nil, nil, name: cname)
        puts "==> #{cname}: removing container"

        # Clean up DID children first
        Kyb::Docker.did_children(cname).each do |did_child|
          puts "       #{did_child}: removing DID child"
          system('docker', 'rm', '-f', did_child)
          system('docker', 'volume', 'rm', "#{did_child}-project", out: File::NULL)
        end

        system('docker', 'rm', '-f', cname)

        Kyb::Docker.volume_rm(c.claude_volume)
        puts
      end
    end

    puts "==> All containers cleaned"
    puts "==> 远端分支未删除，如需清理请手动 git push origin --delete kyb/*"
  end
end
