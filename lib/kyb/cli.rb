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

    Kyb.enable_profile if argv.delete('--profile')

    cmd = argv.first || 'help'
    args = argv[1..] || []

    case cmd
    when 'build'
      build
    when 'init'
      init(args)
    when 'create'
      Kyb.die("create requires a project-branch\n  Usage: kyb create PROJECT-BRANCH [--ports HOST:CONTAINER] [--model flash|pro]") unless args.first
      project, branch = Kyb::Parser.parse(args.shift)
      port_overrides = nil
      model = nil
      if args.first == '--ports'
        args.shift
        port_overrides = args.shift if args.first
      end
      if args.first == '--model'
        args.shift
        model = args.shift
        Kyb.die("--model must be 'flash' or 'pro'") unless %w[flash pro].include?(model)
      end
      create(project, branch, port_overrides, model: model)
    when 'ps', 'ls'
      ps
    when 'enter'
      Kyb.die("enter requires a project-branch\n  Usage: kyb enter PROJECT-BRANCH [--cli claude|kimi|bash]") unless args.first
      project, branch = Kyb::Parser.parse(args.shift)
      cli = 'claude'
      if args.first == '--cli'
        args.shift
        cli = args.shift || 'claude'
        Kyb.die("--cli must be 'claude', 'kimi', or 'bash'") unless %w[claude kimi bash].include?(cli)
      end
      enter(project, branch, cli: cli)
    when 'exec'
      Kyb.die("exec requires a project-branch\n  Usage: kyb exec PROJECT-BRANCH [CMD...]") unless args.first
      project, branch = Kyb::Parser.parse(args.shift)
      exec_cmd(project, branch, args)
    when 'stop'
      Kyb.die("stop requires a project-branch\n  Usage: kyb stop PROJECT-BRANCH") unless args.first
      project, branch = Kyb::Parser.parse(args.shift)
      stop(project, branch)
    when 'start'
      Kyb.die("start requires a project-branch\n  Usage: kyb start PROJECT-BRANCH") unless args.first
      project, branch = Kyb::Parser.parse(args.shift)
      start(project, branch)
    when 'rm'
      Kyb.die("rm requires a project-branch\n  Usage: kyb rm PROJECT-BRANCH") unless args.first
      project, branch = Kyb::Parser.parse(args.shift)
      rm(project, branch)
    when 'prune'
      prune
    when 'sandbox'
      sandbox(args)
    when 'did'
      did(args)
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
      ／人◕ ‿‿ ◕人＼  kyb — kubernate your branches

      Usage:  kyb COMMAND

      Commands:
        build                            Build base image

        init [NAME] [--port PORT] [--symlink PATH] [--env-template FILE]
                                         Add current project to config
        create PROJECT-BRANCH [--ports HOST:CONTAINER] [--model flash|pro]
                                         Create and start a container
        ps, ls                           List containers
        enter PROJECT-BRANCH [--cli claude|kimi|bash]
                                         Enter container (default: claude)
        exec  PROJECT-BRANCH [CMD...]    Run command in container
        stop  PROJECT-BRANCH             Stop container
        start PROJECT-BRANCH             Start stopped container
        rm    PROJECT-BRANCH             Remove container
        prune                            Remove all containers
        sandbox PROJECT-BRANCH [PROMPT]  Run in host sandbox (no Docker)
        sandbox ps, ls                   List host sandboxes
        sandbox rm PROJECT-BRANCH        Remove host sandbox
        did create <name>               DID: create container (Docker-in-Docker)
        did rm <name>                   DID: remove container
        did ps, ls                      DID: list containers
        tts {start|stop|speak...}        macOS TTS controls
        version                          Show version

    EOF
  end
end

require_relative 'cli/build'
require_relative 'cli/init'
require_relative 'cli/create'
require_relative 'cli/enter'
require_relative 'cli/manage'
require_relative 'cli/sandbox'
require_relative 'cli/tts'
require_relative 'cli/did'
