# frozen_string_literal: true

module Kyb::CLI
  DOCKER = 'docker'

  module_function

  def enter(project, branch, cli: 'claude')
    Kyb::Config.load
    container = Kyb::Container.new(project, branch)
    cname = container.name

    ensure_container(container, project, branch)
    stale_msg = stale_image_warning

    title = "kyb:#{cname}"
    prompt = build_default_prompt(stale_msg, project)
    cmd = build_send_keys(cli, project, prompt)
    dexec = docker_exec_args

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

    # After docker exec returns: distinguish detach from session exit
    if tmux_has_session?(cname)
      puts
      puts "==> ⁉ Container #{cname} still alive."
      puts "    Re-attach: kyb enter #{project}-#{branch}"
      return
    end

    Kyb::ExitFlow.enter_exit_cleanup(container, project, branch)
  end

  def ensure_container(container, project, branch)
    cname = container.name
    return if container.running?
    return Kyb::Docker.start_existing(cname) if container.exists?

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
    prompt += " Run `kyb morning` first to see today's status."
    prompt
  end

  def build_send_keys(cli, project, prompt)
    return "cd ~/projects/#{project}" if cli == 'bash'

    kyb = Kyb::Config.kyb_repo ? '/home/dev/kyb/bin/kyb' : 'kyb'
    cmd = "cd ~/projects/#{project} && mise trust && #{kyb} session wrap #{cli}"
    if cli == 'claude'
      cmd += " --dangerously-skip-permissions '#{prompt}'"
    elsif cli == 'kimi'
      cmd += " -p '#{prompt}'"
    end
    cmd
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
