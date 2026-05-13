# frozen_string_literal: true

module Kyb::CLI
  DOCKER = 'docker'

  module_function

  def enter(project, branch, agent: nil)
    Kyb::Config.load
    container = Kyb::Container.new(project, branch)
    cname = container.name

    if container.running?
      # already running, just enter
    elsif container.exists?
      Kyb::Docker.start_existing(cname)
    else
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

    title = "kyb:#{cname}"
    agent_flag = agent ? " --model #{agent}" : ''
    cmd = "cd ~/projects/#{project} && mise trust && claude#{agent_flag} '@CLAUDE.md @README.md @~/.claude/CLAUDE.md 先读一下项目文档和环境说明'"
    dexec = [DOCKER, 'exec', '-it', '-u', 'dev', '-w', '/home/dev']
    dexec += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"] if ENV['KIMI_API_KEY']

    if system('docker', 'exec', '-u', 'dev', cname, 'tmux', 'has-session', '-t', 'dev',
              %i[out err] => File::NULL)
      exec(*dexec, cname, 'tmux',
           'set', '-g', 'set-titles', 'on', ';',
           'set', '-g', 'automatic-rename', 'off', ';',
           'set', '-g', 'set-titles-string', '#{pane_title}', ';',
           'rename-window', title, ';',
           'attach-session', '-t', 'dev')
    else
      exec(*dexec, cname, 'tmux',
           'set', '-g', 'set-titles', 'on', ';',
           'set', '-g', 'automatic-rename', 'off', ';',
           'set', '-g', 'set-titles-string', '#{pane_title}', ';',
           'new-session', '-s', 'dev', '-n', title, ';',
           'select-pane', '-T', title, ';',
           'send-keys', cmd, 'Enter')
    end
  end
end
