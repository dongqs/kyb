# frozen_string_literal: true

module Kyb::CLI
  DOCKER = 'docker'

  module_function

  def enter(project, branch, cli: 'claude')
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

    stale_msg = nil
    if Kyb::Docker.image_exists?(Kyb::Container::BASE_IMAGE)
      path = Kyb::Config.base_image_path
      if Kyb::Docker.stale?(Kyb::Container::BASE_IMAGE, path)
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
        stale_msg = '（基础镜像可能已过时，建议运行 kyb build 更新）'
      end
    end

    title = "kyb:#{cname}"
    cmd = "cd ~/projects/#{project} && mise trust && #{cli}"

    default_prompt = '@CLAUDE.md @README.md @~/.claude/CLAUDE.md 先读一下项目文档和环境说明'
    if stale_msg
      default_prompt += " #{stale_msg}"
    end

    proj_config = Kyb::Config.project(project)
    if proj_config[:extra_prompt]
      default_prompt += " #{proj_config[:extra_prompt]}"
    end

    if cli == 'claude'
      cmd += " '#{default_prompt}'"
    elsif cli == 'kimi'
      cmd += " -p '#{default_prompt}'"
    end
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
