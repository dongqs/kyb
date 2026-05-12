# frozen_string_literal: true

module Kyb::CLI
  DOCKER = 'docker'

  module_function

  def play
    Kyb::Config.load
    path = Kyb::Config.base_image_path
    Kyb::Docker.build(Kyb::Container::BASE_IMAGE, path)

    pc = Kyb::Container.play
    pname = pc.name

    if pc.running?
      puts "==> #{pname} already running, entering..."
    elsif pc.exists?
      Kyb::Docker.start_existing(pname)
    else
      Kyb::Docker.run_play(container: pc, image: Kyb::Container::BASE_IMAGE)
      30.times do
        break if system('docker', 'exec', '-u', 'dev', pname,
                        'test', '-f', '/home/dev/.claude/settings.json',
                        out: File::NULL, err: File::NULL)
        sleep 0.5
      end
    end

    title = 'kyb:play'
    cmd = 'claude'
    dexec = [DOCKER, 'exec', '-it', '-u', 'dev', '-w', '/home/dev']
    dexec += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"] if ENV['KIMI_API_KEY']

    if system('docker', 'exec', '-u', 'dev', pname, 'tmux', 'has-session', '-t', 'dev',
              %i[out err] => File::NULL)
      exec(*dexec, pname, 'tmux',
           'set', '-g', 'set-titles', 'on', ';',
           'set', '-g', 'automatic-rename', 'off', ';',
           'set', '-g', 'set-titles-string', '#{pane_title}', ';',
           'rename-window', title, ';',
           'attach-session', '-t', 'dev')
    else
      exec(*dexec, pname, 'tmux',
           'set', '-g', 'set-titles', 'on', ';',
           'set', '-g', 'automatic-rename', 'off', ';',
           'set', '-g', 'set-titles-string', '#{pane_title}', ';',
           'new-session', '-s', 'dev', '-n', title, ';',
           'select-pane', '-T', title, ';',
           'send-keys', cmd, 'Enter')
    end
  end

  def enter(project, branch)
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
    cmd = "cd ~/projects/#{project} && mise trust && claude"
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
