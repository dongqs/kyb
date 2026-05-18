# frozen_string_literal: true

module Kyb::ExitFlow
  module_function

  def enter_exit_cleanup(container, project, branch)
    cname = container.name
    puts
    puts "==> Container #{cname}: session ended."

    checks = run_idle_checks(container, project)
    all_pass = checks.values_at(:tmux, :worktree, :remote).all?

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
    wt_path = container.worktree_path
    dind = File.exist?('/.dockerenv')

    puts
    puts "━━━  Idle Check  ━━━"

    tmux_dead = !system('docker', 'exec', '-u', 'dev', cname, 'tmux', 'has-session', '-t', 'dev',
                        %i[out err] => File::NULL)
    puts tmux_dead ? "  ✔ tmux:     no active sessions" : "  ✘ tmux:     session still alive"

    worktree_clean = if dind
                       system('docker', 'exec', '-u', 'dev', cname,
                              'git', '-C', "/home/dev/projects/#{project}", 'diff', '--quiet',
                              %i[out err] => File::NULL)
                     elsif wt_path && File.exist?("#{wt_path}/.git")
                       system('git', '--git-dir', "#{wt_path}/.git", '--work-tree', wt_path,
                              'diff', '--quiet', %i[out err] => File::NULL)
                     else
                       true
                     end
    puts worktree_clean ? "  ✔ worktree: clean" : "  ✘ worktree: uncommitted changes"

    remote_ok = if dind
                  `docker exec -u dev #{cname} bash -c 'cd /home/dev/projects/#{project} && git cherry' 2>/dev/null`.lines.count == 0
                elsif wt_path && File.exist?("#{wt_path}/.git")
                  Dir.chdir(wt_path) { `git cherry 2>/dev/null`.lines.count == 0 }
                else
                  false
                end
    puts remote_ok ? "  ✔ remote:   all pushed" : "  ✘ remote:   unpushed commits"

    { tmux: tmux_dead, worktree: worktree_clean, remote: remote_ok }
  end

  def collect_extra_warnings(container)
    cname = container.name
    warnings = []

    baseline = %w[ps tmux bash zsh sh sleep postgres pg_ctl sshd entrypoint runuser
                  claude kyb ruby python3 node tail dumb-init nginx]
    processes = `docker exec #{cname} ps -eo comm= 2>/dev/null`.lines.map(&:strip).reject(&:empty?).uniq
    unexpected = processes - baseline
    warnings << "processes: #{unexpected.join(', ')}" if unexpected.any?

    did_kids = `docker ps -a --format '{{.Names}}' --filter label=did_parent=#{cname} 2>/dev/null`
               .lines.map(&:strip).reject(&:empty?)
    warnings << "DID children: #{did_kids.join(', ')} (will be cascade deleted)" if did_kids.any?

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
    puts "  • delete worktree & git branch #{container.git_branch}"
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

    `docker ps -a --format '{{.Names}}' --filter label=did_parent=#{cname}`.lines.map(&:strip).each do |did_child|
      puts "==> #{did_child}: removing DID child container"
      system('docker', 'rm', '-f', did_child)
      system('docker', 'volume', 'rm', "#{did_child}-worktree", out: File::NULL)
    end

    puts "==> #{cname}: stopping"
    system('docker', 'stop', cname)
    puts "==> #{cname}: removing"
    system('docker', 'rm', cname)

    proj_config = Kyb::Config.project(project) rescue nil
    if proj_config && proj_config[:path]
      path = proj_config[:path]
      wt_path = container.worktree_path
      if wt_path && File.directory?(wt_path)
        Kyb::Git.remove_worktree(path, wt_path)
      end
      Kyb::Git.delete_local_branch(path, container)
    end

    Kyb::Docker.volume_rm(container.claude_volume)

    puts "==> Done. Container cleaned."
    puts
    puts "    Start fresh: kyb create #{project}-#{branch}"
  end
end
