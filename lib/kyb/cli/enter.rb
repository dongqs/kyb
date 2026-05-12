# frozen_string_literal: true

module Kyb::CLI
  PLAY_CONTAINER = 'dev-play'

  module_function

  def title(text)
    print "\e]0;#{text}\a" if STDOUT.tty?
  end

  def play
    Kyb::Config.load
    path = Kyb::Config.base_image_path
    Kyb::Docker.build(Kyb::BASE_IMAGE, path)

    if Kyb::Docker.running?(PLAY_CONTAINER)
      puts "==> #{PLAY_CONTAINER} already running, entering..."
    elsif Kyb::Docker.exists?(PLAY_CONTAINER)
      Kyb::Docker.start_existing(PLAY_CONTAINER)
    else
      Kyb::Docker.run_play(container: PLAY_CONTAINER, image: Kyb::BASE_IMAGE)
      30.times do
        break if system('docker', 'exec', '-u', 'dev', PLAY_CONTAINER,
                        'test', '-f', '/home/dev/.claude/settings.json',
                        out: File::NULL, err: File::NULL)
        sleep 0.5
      end
    end

    cmd = 'claude'
    dexec = ['docker', 'exec', '-it', '-u', 'dev', '-w', '/home/dev']
    dexec += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"] if ENV['KIMI_API_KEY']

    title("kyb:play")
    if system('docker', 'exec', '-u', 'dev', PLAY_CONTAINER, 'tmux', 'has-session', '-t', 'dev',
              %i[out err] => File::NULL)
      exec(*dexec, PLAY_CONTAINER, 'tmux', 'set', '-g', 'set-titles', 'on', ';',
           'set', '-g', 'set-titles-string', title_str(PLAY_CONTAINER), ';',
           'attach-session', '-t', 'dev')
    else
      exec(*dexec, PLAY_CONTAINER, 'tmux', 'set', '-g', 'set-titles', 'on', ';',
           'set', '-g', 'set-titles-string', title_str(PLAY_CONTAINER), ';',
           'new-session', '-s', 'dev', ';',
           'select-pane', '-T', "kyb:play", ';',
           'send-keys', cmd, 'Enter')
    end
  end

  def enter(name, suffix = nil)
    Kyb::Config.load
    container = Kyb::Docker.container_name(name, suffix)

    if Kyb::Docker.running?(container)
      # already running, just enter
    elsif Kyb::Docker.exists?(container)
      Kyb::Docker.start_existing(container)
    else
      print "==> #{container}: sandbox not found. Create it? [Y/n] (10s) "
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
        Kyb::Docker.create_container(name, suffix)
      else
        puts
        puts "==> Run `kyb create #{name}#{suffix ? " #{suffix}" : ''}` to create it manually"
        exit 0
      end
    end

    cmd = "cd ~/projects/#{name} && mise trust && claude"
    dexec = ['docker', 'exec', '-it', '-u', 'dev', '-w', '/home/dev']
    dexec += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"] if ENV['KIMI_API_KEY']

    title("kyb:#{container}")
    if system('docker', 'exec', '-u', 'dev', container, 'tmux', 'has-session', '-t', 'dev',
              %i[out err] => File::NULL)
      exec(*dexec, container, 'tmux', 'set', '-g', 'set-titles', 'on', ';',
           'set', '-g', 'set-titles-string', title_str(container), ';',
           'attach-session', '-t', 'dev')
    else
      exec(*dexec, container, 'tmux', 'set', '-g', 'set-titles', 'on', ';',
           'set', '-g', 'set-titles-string', title_str(container), ';',
           'new-session', '-s', 'dev', ';',
           'select-pane', '-T', "kyb:#{container}", ';',
           'send-keys', cmd, 'Enter')
    end
  end

  def title_str(container)
    "kyb:#{container} — \#{pane_title}"
  end

end
