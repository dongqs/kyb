# frozen_string_literal: true

require 'shellwords'

module Kyb::CLI
  DOCKER = 'docker'

  module_function

  def enter(project, branch, cli: 'claude', worldview: nil)
    Kyb::Config.load
    container = Kyb::Container.new(project, branch)
    cname = container.name

    Kyb::Reporter.emit_session_start(project: project, cli_type: cli)

    ensure_container(container, project, branch)
    stale_msg = stale_image_warning

    worldview_name = resolve_worldview(worldview, cname)

    title = "kyb:#{cname}"
    prompt = build_default_prompt(stale_msg, project)
    prompt = inject_worldview(prompt, worldview_name) if worldview_name
    cmd = build_send_keys(cli, project, prompt)
    dexec = docker_exec_args

    enter_container(cname, title: title, cmd: cmd, dexec: dexec)

    # After docker exec returns: distinguish detach from session exit
    if tmux_has_session?(cname)
      puts
      puts "==> ⁉ Container #{cname} still alive."
      puts "    Re-attach: kyb enter #{project}-#{branch}"
      return
    end

    Kyb::ExitFlow.enter_exit_cleanup(container, project, branch)
  end

def resolve_worldview(cli_worldview, container_name)
    return cli_worldview if cli_worldview
    stored = Kyb::Worldview.assigned(container_name)
    return stored if stored
    nil
  end
  def ensure_container(container, project, branch)
    cname = container.name
    return if container.running?

    if container.exists?
      Kyb::Docker.start_existing(cname)
      sleep 1
      unless container.running?
        logs = `docker logs #{cname} --tail 30 2>/dev/null`.strip
        msg = "container '#{cname}' exited immediately after start.\n" \
              "  The entrypoint may be crashing. Container logs:\n"
        msg += logs.empty? ? "  (no logs)\n" : logs.lines.map { |l| "  | #{l}" }.join
        Kyb.die(msg)
      end
      return
    end

    unless STDIN.tty?
      Kyb::Docker.create_container(project, branch)
      return
    end

    id = "#{project}-#{branch}"
    print "==> #{cname}: container not found. Create it? [Y/n] (10s) "
    STDOUT.flush
    input = nil
    begin
      input = if IO.select([STDIN], nil, nil, 10)
                STDIN.gets.to_s.strip.downcase
              end
    rescue Interrupt
      puts
      exit 0
    end
    if input == 'y' || input == 'yes' || input == ''
      Kyb::Docker.create_container(project, branch)
    else
      puts
      puts "==> Run `kyb create #{id}` to create it manually"
      exit 0
    end
  end

  def stale_image_warning
    return nil unless Kyb::Docker.image_exists?(Kyb::Container::BASE_IMAGE)
    path = Kyb::Config.base_image_path
    return nil unless Kyb::Docker.stale?(Kyb::Container::BASE_IMAGE, path)

    puts
    puts "==> ⚠ kyb-base:latest is outdated (Dockerfile changed)."
    puts "    Run 'kyb build' on host to update."
    print "    Continue? [Y/n] (5s auto: Y) "
    STDOUT.flush
    input = IO.select([STDIN], nil, nil, 5)
    if input
      ans = STDIN.gets.to_s.strip.downcase
      if ans == 'n' || ans == 'no'
        puts "    Aborted."
        exit 0
      end
    else
      puts
    end
    '（基础镜像可能已过时，建议运行 kyb build 更新）'
  end

  def build_default_prompt(stale_msg, project)
    prompt = '@CLAUDE.md @README.md @~/.claude/CLAUDE.md 先读一下项目文档和环境说明'
    prompt += " #{stale_msg}" if stale_msg
    proj = Kyb::Config.project(project)
    prompt += " #{proj[:extra_prompt]}" if proj[:extra_prompt]
    prompt += " 先运行 kyb morning 查看今日状态"
    prompt
  end

  def build_send_keys(cli, project, prompt)
    return "cd ~/projects/#{project}" if cli == 'bash'

    kyb = Kyb::Config.kyb_repo ? '/home/dev/kyb/bin/kyb' : 'kyb'
    cmd = "cd ~/projects/#{project} && mise trust && #{kyb} session wrap #{cli}"
    if cli == 'claude'
      cmd += " --dangerously-skip-permissions #{Shellwords.escape(prompt)}"
    elsif cli == 'kimi'
      cmd += " -p #{Shellwords.escape(prompt)}"
    end
    cmd
  end

  def enter_container(cname, title:, cmd:, dexec:)
    if tmux_has_session?(cname)
      system(*dexec, cname, 'tmux',
             'set', '-g', 'set-titles', 'on', ';',
             'set', '-g', 'automatic-rename', 'off', ';',
             'set', '-g', 'set-titles-string', '#{pane_title}', ';',
             'rename-window', title, ';',
             'attach-session', '-t', 'dev')
    else
      system(*dexec, cname, 'tmux',
             'set', '-g', 'set-titles', 'on', ';',
             'set', '-g', 'automatic-rename', 'off', ';',
             'set', '-g', 'set-titles-string', '#{pane_title}', ';',
             'new-session', '-s', 'dev', '-n', title, ';',
             'select-pane', '-T', title, ';',
             'send-keys', cmd, 'Enter')
    end
  end

  def tmux_has_session?(cname)
    system('docker', 'exec', '-u', 'dev', cname, 'tmux', 'has-session', '-t', 'dev',
           %i[out err] => File::NULL)
  end

  def docker_exec_args
    dexec = [DOCKER, 'exec', '-it', '-u', 'dev', '-w', '/home/dev']
    dexec += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"] if ENV['KIMI_API_KEY']
    dexec
  end
end

require_relative '../exit_flow'
