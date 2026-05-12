# frozen_string_literal: true

module Kyb::CLI
  module_function

  def dispatch(argv)
    gitconfig = File.expand_path('~/.gitconfig')
    FileUtils.touch(gitconfig) unless File.exist?(gitconfig)

    glab_config = File.expand_path('~/Library/Application Support/glab-cli/config.yml')
    if File.exist?(glab_config)
      token = YAML.safe_load_file(glab_config, permitted_classes: [Symbol, Time]) rescue nil
      ENV['GITLAB_TOKEN'] ||= token&.dig('hosts', 'git.leyantech.com', 'token').to_s
    end

    cmd = argv.first || 'help'
    args = argv[1..] || []

    case cmd
    when 'build'
      build
    when 'play'
      play
    when 'init'
      init(args)
    when 'create'
      Kyb.die("create requires a project name\n  Usage: kyb create NAME [SUFFIX] [--ports HOST:CONTAINER]") unless args.first
      name = args.shift
      suffix = nil
      port_overrides = nil
      i = 0
      while i < args.size
        case args[i]
        when '--ports'
          port_overrides = args[i + 1] if args[i + 1]
          i += 2
        else
          suffix = args[i] unless args[i].start_with?('--')
          i += 1
        end
      end
      create(name, suffix, port_overrides)
    when 'ps', 'ls'
      ps
    when 'enter'
      Kyb.die("enter requires a project name\n  Usage: kyb enter NAME [SUFFIX]") unless args.first
      enter(args[0], args[1])
    when 'exec'
      Kyb.die("exec requires a project name\n  Usage: kyb exec NAME [SUFFIX] [--] CMD...") unless args.first
      exec_cmd(args[0], args[1..] || [])
    when 'stop'
      stop(args[0], args[1])
    when 'start'
      start(args[0], args[1])
    when 'rm'
      rm(args[0], args[1])
    when 'prune'
      prune
    when 'tts'
      Kyb.die("tts requires a subcommand\n  Usage: kyb tts {start|stop|status|speak|ping|done}") unless args.first
      case args[0]
      when 'start'  then tts_start
      when 'stop'   then tts_stop
      when 'status' then tts_status
      when 'speak'  then tts_speak(args[1..].join(' '))
      when 'ping'   then tts_ping
      when 'done'   then tts_done(args[1..].join(' '))
      else Kyb.die("unknown tts subcommand: #{args[0]}")
      end
    when 'version', '--version', '-v'
      puts "kyb #{Kyb::VERSION}"
    when 'help', '--help', '-h'
      help
    else
      help
    end
  end

  def help
    puts <<~EOF
      (◕‿‿◕)  kyb — kubernate your branches

      Usage:  kyb COMMAND

      Commands:
        build                     Build base image
        play                      Launch disposable sandbox (no project)
        init [NAME] [--port PORT] [--symlink PATH] [--env-template FILE]
                                  Add current project to config
        create NAME [SUFFIX] [--ports HOST:CONTAINER]
                                  Create and start a sandbox
        ps, ls                    List sandbox containers
        enter NAME [SUFFIX]       Enter sandbox via interactive shell
        exec  NAME [SUFFIX] -- CMD
                                  Run command in sandbox
        stop  NAME [SUFFIX]       Stop sandbox container
        start NAME [SUFFIX]       Start stopped sandbox container
        rm    NAME [SUFFIX]       Remove sandbox completely
        prune                     Remove all sandboxes
        tts {start|stop|speak...} macOS TTS controls
        version                   Show version

    EOF
  end
end

require_relative 'cli/build'
require_relative 'cli/init'
require_relative 'cli/create'
require_relative 'cli/enter'
require_relative 'cli/manage'
require_relative 'cli/tts'
