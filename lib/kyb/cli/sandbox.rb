# frozen_string_literal: true

require 'json'
require 'shellwords'

module Kyb::CLI
  NODE_MODULES_BASE = File.expand_path('~/.kyb/node_modules')
  SANDBOX_WORKTREE_BASE = File.expand_path('~/.kyb/worktrees')

  module_function

  def sandbox(args)
    case args.first
    when 'ps', 'ls'
      sandbox_ps
    when 'rm'
      Kyb.die("rm requires a project-branch\n  Usage: kyb sandbox rm PROJECT-BRANCH") unless args[1]
      project, branch = Kyb::Parser.parse(args[1])
      sandbox_rm(project, branch)
    else
      Kyb.die("sandbox requires a project-branch\n  Usage: kyb sandbox PROJECT-BRANCH [PROMPT]") unless args.first
      project, branch = Kyb::Parser.parse(args.first)
      prompt = args[1..]&.join(' ')
      prompt = nil if prompt&.empty?
      sandbox_create(project, branch, prompt)
    end
  end

  # -- paths ------------------------------------------------------------

  def sandbox_worktree_path(project, branch)
    name = Kyb::Container.new(project, branch).name
    File.join(SANDBOX_WORKTREE_BASE, project, name)
  end

  def sandbox_ports_path(wt_path)
    File.join(wt_path, '.kyb-ports')
  end

  def sandbox_pid_path(wt_path)
    File.join(wt_path, '.kyb-pid')
  end

  def sandbox_claude_md_path(wt_path)
    File.join(wt_path, '.kyb-claude.md')
  end

  # -- ports ------------------------------------------------------------

  def sandbox_allocated_ports
    ports = {}
    return ports unless File.directory?(SANDBOX_WORKTREE_BASE)
    Dir.glob(File.join(SANDBOX_WORKTREE_BASE, '*', '*', '.kyb-ports')).each do |f|
      name = File.basename(File.dirname(f))
      content = File.read(f).strip
      ports[name] = content.split(',').map(&:to_i).reject(&:zero?) unless content.empty?
    end
    ports
  end

  def sandbox_assign_port(container_ports)
    allocated = sandbox_allocated_ports.values.flatten
    assigned = []
    container_ports.map do |cport|
      port = cport
      while port_in_use?(port) || allocated.include?(port) || assigned.include?(port)
        port += 1
      end
      assigned << port
      port
    end
  end

  def port_in_use?(port)
    TCPServer.new('0.0.0.0', port).close
    false
  rescue Errno::EADDRINUSE
    true
  end

  # -- process ----------------------------------------------------------

  def process_alive?(pid)
    return false if pid.nil? || pid <= 0
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # -- create -----------------------------------------------------------

  def sandbox_create(project, branch, prompt = nil)
    Kyb::Config.load
    proj = Kyb::Config.project(project)
    path = proj[:path]
    container = Kyb::Container.new(project, branch)
    wt_path = sandbox_worktree_path(project, branch)
    ports = sandbox_assign_port(proj[:ports])

    # Check if already running
    pid_path = sandbox_pid_path(wt_path)
    if File.exist?(pid_path)
      old_pid = File.read(pid_path).strip.to_i
      if process_alive?(old_pid)
        Kyb.die("sandbox '#{container.name}' is already running (pid #{old_pid})")
      end
      puts "==> cleaning up stale pid #{old_pid}"
      FileUtils.rm_f(pid_path)
    end

    # Setup worktree
    if File.directory?(wt_path)
      puts "==> worktree exists, reusing (#{wt_path})"
    else
      Kyb::Git.setup_worktree(path, proj[:base_branch], wt_path, container)
    end

    # Ports file
    ports_path = sandbox_ports_path(wt_path)
    File.write(ports_path, ports.join(',')) unless ports.empty?

    # Shared node_modules
    shared_modules = File.join(NODE_MODULES_BASE, project)
    wt_modules = File.join(wt_path, 'node_modules')
    unless File.symlink?(wt_modules)
      FileUtils.rm_rf(wt_modules) if File.exist?(wt_modules)
      FileUtils.mkdir_p(shared_modules)
      File.symlink(shared_modules, wt_modules)
    end

    # Symlinks from config
    proj[:symlinks].to_s.split(',').each do |link|
      next if link.empty?
      src = File.join(path, link)
      dst = File.join(wt_path, link)
      next if File.symlink?(dst)
      FileUtils.rm_rf(dst) if File.exist?(dst)
      next unless File.exist?(src)
      FileUtils.mkdir_p(File.dirname(dst))
      File.symlink(src, dst)
    end

    # Env template
    if proj[:env_template] && !proj[:env_template].empty?
      src = File.join(path, proj[:env_template])
      dst = File.join(wt_path, '.env')
      unless File.exist?(dst)
        puts "     cp #{src} -> .env"
        FileUtils.cp(src, dst)
      end
    end

    # Project-level Claude settings (sandbox + permissions)
    write_sandbox_settings(wt_path, project)

    # CLAUDE.md context
    write_sandbox_claude_md(wt_path, project, branch, path, ports, proj)

    # Write pid (current process — exec preserves PID)
    File.write(pid_path, Process.pid.to_s)

    # Pre-install dependencies (runs outside sandbox, avoids network prompts)
    if system('which', 'mise', out: File::NULL, err: File::NULL)
      system('mise', 'trust', chdir: wt_path)
    end
    if File.exist?(File.join(wt_path, 'package.json'))
      nm = File.join(wt_path, 'node_modules')
      unless File.directory?(nm) && !Dir.empty?(nm)
        puts '==> npm install (shared)'
        system('npm', 'install', chdir: wt_path)
      end
    end

    # Build Claude Code arguments
    claude_args = ['--dangerously-skip-permissions']

    # @file context references
    [
      [File.join(wt_path, 'CLAUDE.md'), '@CLAUDE.md'],
      [File.join(wt_path, 'README.md'), '@README.md'],
      [sandbox_claude_md_path(wt_path), '@.kyb-claude.md'],
      [File.expand_path('~/.claude/CLAUDE.md'), '@~/.claude/CLAUDE.md']
    ].each do |file, ref|
      claude_args << ref if File.exist?(file)
    end

    if prompt
      claude_args += ['-p', prompt]
    else
      claude_args << '先读一下项目文档和环境说明'
    end

    # Pass assigned ports as environment variable (vite etc. auto-detect PORT)
    ENV['PORT'] = ports.first.to_s unless ports.empty?

    Dir.chdir(wt_path)
    exec('claude', *claude_args)
  rescue Errno::ENOENT
    Kyb.die('claude not found in PATH. Is Claude Code installed?')
  end

  def write_sandbox_settings(wt_path, project)
    settings_dir = File.join(wt_path, '.claude')
    FileUtils.mkdir_p(settings_dir)
    settings_path = File.join(settings_dir, 'settings.json')
    settings = {
      sandbox: {
        enabled: true,
        network: {
          allowedDomains: [
            '*.npmjs.org',
            '*.npmmirror.com',
            'registry.npmjs.org',
            'registry.npmmirror.com',
            'github.com',
            '*.github.com',
            '*.githubusercontent.com',
            'git.leyantech.com',
            '*.leyantech.com',
            'nexus.leyantech.com',
            'api.anthropic.com',
            'api.deepseek.com',
            '*.deepseek.com',
            'localhost',
            '127.0.0.1'
          ]
        },
        filesystem: {
          allowWrite: [NODE_MODULES_BASE + '/' + project]
        },
        excludedCommands: [
          'npm run *',
          'npm start',
          'npx *',
          'vite',
          'next',
          'webpack',
          'python -m http.server',
          'ruby -run'
        ]
      },
      permissions: { allow: ['*'] },
      skipDangerousModePermissionPrompt: true
    }
    File.write(settings_path, JSON.pretty_generate(settings))
  end

  def write_sandbox_claude_md(wt_path, project, branch, project_path, ports, proj)
    mounts_text = ''
    if proj[:mounts_rw] && !proj[:mounts_rw].empty?
      mounts_text += "## Read-Write Host Paths\n"
      proj[:mounts_rw].split(',').each do |m|
        host, _container = m.split(':', 2)
        mounts_text += "- `#{host}` (host path, directly accessible)\n"
      end
    end
    if proj[:mounts_ro] && !proj[:mounts_ro].empty?
      mounts_text += "\n## Read-Only Host Paths\n"
      proj[:mounts_ro].split(',').each do |m|
        host, _container = m.split(':', 2)
        mounts_text += "- `#{host}` (host path, directly accessible)\n"
      end
    end

    ports_text = ports.empty? ? 'none' : ports.join(', ')
    db_name = "#{project}_#{branch.gsub('-', '_')}"

    content = <<~CLAUDE
      # Sandbox Environment

      You are running in a **kyb sandbox** for project #{project}.
      Your actions are sandboxed by Claude Code sandbox (filesystem + network boundaries).

      ## Project
      - **Name**: #{project}
      - **Path**: #{wt_path}
      - **Branch**: kyb/#{project}-#{branch}
      - **Original repo**: #{project_path}

      ## Services
      - **PostgreSQL 16** — running on host, trust auth, timezone Asia/Shanghai
        - Connect at `postgresql://postgres:postgres@127.0.0.1:5432/postgres`
        - Create a database for this sandbox if needed: `CREATE DATABASE #{db_name};`
      - **Network proxy** — if you need to access external services (GitHub, APIs, etc.):
        ```
        export ALL_PROXY=socks5://127.0.0.1:2080
        ```
        Internal hosts (git.leyantech.com, .leyantech.com, nexus.leyantech.com) go directly.
        Set NO_PROXY to exclude internal hosts.

      ## Node modules
      - `node_modules` is shared across all sandboxes for project `#{project}`
      - Run `npm install` if dependencies are missing
      - Other sandboxes may also be modifying dependencies — coordinate if needed

      ## Ports
      - This sandbox has assigned ports: #{ports_text}
      - Use these ports when starting dev servers
      - Dev server commands (`npm run dev`, `vite`, etc.) are excluded from sandbox
        and run with full network access — no permission prompts needed
    CLAUDE

    if mounts_text.empty?
      content += "\nNo additional host mounts configured.\n"
    else
      content += "\n#{mounts_text}"
    end

    File.write(sandbox_claude_md_path(wt_path), content)
  end

  # -- ps ---------------------------------------------------------------

  def sandbox_ps
    unless File.directory?(SANDBOX_WORKTREE_BASE)
      puts '(no sandboxes)'
      return
    end

    rows = []
    Dir.glob(File.join(SANDBOX_WORKTREE_BASE, '*', '*')).each do |wt_path|
      next unless File.directory?(wt_path)
      name = File.basename(wt_path)
      project = File.basename(File.dirname(wt_path))

      pid = nil
      pid_path = sandbox_pid_path(wt_path)
      if File.exist?(pid_path)
        pid = File.read(pid_path).strip.to_i
      end

      ports = ''
      ports_path = sandbox_ports_path(wt_path)
      if File.exist?(ports_path)
        ports = File.read(ports_path).strip
      end

      status = if pid && process_alive?(pid)
                 'running'
               else
                 'stopped'
               end

      rows << [project, name, pid.to_s, ports, status]
    end

    if rows.empty?
      puts '(no sandboxes)'
      return
    end

    fmt = "%-10s %-26s %-8s %-10s %s"
    puts format(fmt, 'PROJECT', 'SANDBOX', 'PID', 'PORTS', 'STATUS')
    rows.each do |project, name, pid, ports, status|
      puts format(fmt, project, name, pid, ports, status)
    end
  end

  # -- rm ---------------------------------------------------------------

  def sandbox_rm(project, branch)
    Kyb::Config.load
    proj = Kyb::Config.project(project)
    wt_path = sandbox_worktree_path(project, branch)
    container = Kyb::Container.new(project, branch)

    return unless File.directory?(wt_path)

    # Kill main process if running
    pid_path = sandbox_pid_path(wt_path)
    if File.exist?(pid_path)
      pid = File.read(pid_path).strip.to_i
      if process_alive?(pid)
        puts "==> killing process #{pid}"
        Process.kill('TERM', pid)
        sleep 0.5
        Process.kill('KILL', pid) rescue nil if process_alive?(pid)
      end
    end

    # Kill processes holding assigned ports (dev servers etc.)
    ports_path = sandbox_ports_path(wt_path)
    if File.exist?(ports_path)
      File.read(ports_path).strip.split(',').map(&:to_i).each do |port|
        `lsof -ti :#{port} 2>/dev/null`.lines.map(&:strip).each do |pid|
          pid = pid.to_i
          next if pid <= 0
          puts "==> killing port #{port} (pid #{pid})"
          Process.kill('TERM', pid) rescue nil
        end
      end
    end

    # Remove worktree
    Kyb::Git.remove_worktree(proj[:path], wt_path)

    # Delete branches
    Kyb::Git.delete_local_branch(proj[:path], container)
    Kyb::Git.delete_remote_branch(proj[:path], container)

    puts "==> #{container.name}: sandbox removed"
  end
end
