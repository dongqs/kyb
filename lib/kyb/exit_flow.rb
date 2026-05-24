# frozen_string_literal: true

require 'open3'

module Kyb::ExitFlow
  module_function

  def enter_exit_cleanup(container, project, branch)
    cname = container.name
    puts
    puts "==> Container #{cname}: session ended."

    checks = run_idle_checks(container, project)
    all_pass = checks.values_at(:tmux, :dirty, :remote).all?

    if all_pass
      warnings = collect_extra_warnings(container)
      warnings.each { |w| puts "  ⚠  #{w}" } if warnings.any?
      puts
      interactive_delete_prompt(container, project, branch)
    else
      puts
      puts "    Cleanup skipped (see warnings above)."
      puts "    Force delete: kyb rm #{project}-#{branch}"
    end
  end

  def run_idle_checks(container, project)
    cname = container.name
    dind = Kyb.in_container?

    puts
    puts "━━━  Idle Check  ━━━"

    tmux_dead = !system('docker', 'exec', '-u', 'dev', cname, 'tmux', 'has-session', '-t', 'dev',
                        %i[out err] => File::NULL)
    puts tmux_dead ? "  ✔ tmux:     no active sessions" : "  ✘ tmux:     session still alive"

    # Check host repo diff
    repo_path = nil
    unless dind
      begin
        proj = Kyb::Config.project(project)
        repo_path = proj[:path]
      rescue StandardError
      end
    end

    clean = if dind
               system('docker', 'exec', '-u', 'dev', cname,
                      'git', '-C', "/home/dev/projects/#{project}", 'diff', '--quiet',
                      %i[out err] => File::NULL)
             elsif repo_path && File.directory?("#{repo_path}/.git")
               Dir.chdir(repo_path) { system('git', 'diff', '--quiet', %i[out err] => File::NULL) }
             else
               true
             end
    puts clean ? "  ✔ repo:     clean" : "  ✘ repo:     uncommitted changes"

    remote_ok = if dind
                  begin
                    Open3.capture3('docker', 'exec', '-u', 'dev', cname, 'bash', '-c', "cd /home/dev/projects/#{project} && git cherry").first.lines.count == 0
                  rescue Errno::ENOENT
                    true
                  end
                elsif repo_path && File.directory?("#{repo_path}/.git")
                  Dir.chdir(repo_path) { `git cherry 2>/dev/null`.lines.count == 0 }
                else
                  false
                end
    puts remote_ok ? "  ✔ remote:   all pushed" : "  ✘ remote:   unpushed commits"

    { tmux: tmux_dead, dirty: clean, remote: remote_ok }
  end

  def collect_extra_warnings(container)
    cname = container.name
    warnings = []

    baseline = %w[ps tmux bash zsh sh sleep postgres pg_ctl sshd entrypoint runuser
                  claude kyb ruby python3 node tail dumb-init nginx]
    begin
      processes = Open3.capture3('docker', 'exec', cname, 'ps', '-eo', 'comm=').first.lines.map(&:strip).reject(&:empty?).uniq
      unexpected = processes - baseline
      warnings << "processes: #{unexpected.join(', ')}" if unexpected.any?

      did_kids = Open3.capture3('docker', 'ps', '-a', '--format', '{{.Names}}', '--filter', "label=did_parent=#{cname}").first
                 .lines.map(&:strip).reject(&:empty?)
      warnings << "DID children: #{did_kids.join(', ')} (will be cascade deleted)" if did_kids.any?
    rescue Errno::ENOENT
    end

    warnings
  end

  def interactive_delete_prompt(container, project, branch)
    cname = container.name
    puts "━━━  Container Idle  ━━━━━━━━━━━━━"
    puts "Container:  #{cname}"
    puts "Project:    #{project} / #{branch}"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts "Cleanup will:"
    puts "  • stop & remove container"
    puts "  • remove claude volume"
    puts
    print "Delete container? [y/N] (5s auto: skip) "
    STDOUT.flush

    input = nil
    begin
      if IO.select([STDIN], nil, nil, 5)
        input = STDIN.gets.to_s.strip.downcase
      end
    rescue Interrupt
    end

    if input == 'y'
      perform_cleanup(container, project, branch)
    else
      puts
      puts "==> Cleanup skipped."
      puts "    Delete manually: kyb rm #{project}-#{branch}"
      puts "    Re-attach:       kyb enter #{project}-#{branch}"
    end
  end

  def perform_cleanup(container, project, branch)
    cname = container.name
    puts

    begin
      did_children = Open3.capture3('docker', 'ps', '-a', '--format', '{{.Names}}', '--filter', "label=did_parent=#{cname}").first
    rescue Errno::ENOENT
      did_children = ""
    end
    did_children.lines.map(&:strip).each do |did_child|
      puts "==> #{did_child}: removing DID child container"
      system('docker', 'rm', '-f', did_child)
      system('docker', 'volume', 'rm', "#{did_child}-project", out: File::NULL)
    end

    puts "==> #{cname}: stopping"
    system('docker', 'stop', cname)
    puts "==> #{cname}: removing"
    system('docker', 'rm', cname)

    Kyb::Docker.volume_rm(container.claude_volume)

    clone_target = Kyb::Docker.clone_path(project, container) rescue nil
    if clone_target && File.directory?(clone_target)
      puts "==> removing clone #{clone_target}"
      FileUtils.rm_rf(clone_target)
    end

    puts "==> Done. Container cleaned."
    puts
    puts "    Start fresh: kyb create #{project}-#{branch}"
  end
end
