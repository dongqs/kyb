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
    when 'doctor'
      doctor(args)
    when 'onboard'
      onboard(args)
    when 'preflight', 'pre-flight', 'check'
      preflight
    when 'build'
      build
    when 'init'
      init(args)
    when 'create'
      Kyb.die("create requires a project-branch\n  Usage: kyb create PROJECT-BRANCH [--clone] [--ports HOST:CONTAINER] [--model flash|pro]") unless args.first
      repo_root = args.delete('--clone') ? 'isolated_local_repo_clone' : nil
      port_overrides = nil
      model = nil
      project, branch = Kyb::Parser.parse(args.shift)
      if args.first == '--ports'
        args.shift
        port_overrides = args.shift if args.first
      end
      if args.first == '--model'
        args.shift
        model = args.shift
        Kyb.die("--model must be 'flash' or 'pro'") unless %w[flash pro].include?(model)
      end
      create(project, branch, port_overrides, model: model, repo_root: repo_root)
    when 'ps', 'ls'
      ps
    when 'enter'
      project, branch = if args.first
                          Kyb::Parser.parse(args.shift)
                        elsif (detected = Kyb::Parser.auto_detect)
                          detected
                        else
                          Kyb.die("enter requires a project-branch")
                        end
      cli = 'claude'
      if args.first == '--cli'
        args.shift
        cli = args.shift || 'claude'
        Kyb.die("--cli must be 'claude', 'kimi', or 'bash'") unless %w[claude kimi bash].include?(cli)
      end
      enter(project, branch, cli: cli)
    when 'exec'
      project, branch = if args.first
                          Kyb::Parser.parse(args.shift)
                        elsif (detected = Kyb::Parser.auto_detect)
                          detected
                        else
                          Kyb.die("exec requires a project-branch")
                        end
      exec_cmd(project, branch, args)
    when 'stop'
      project, branch = if args.first
                          Kyb::Parser.parse(args.shift)
                        elsif (detected = Kyb::Parser.auto_detect)
                          detected
                        else
                          Kyb.die("stop requires a project-branch")
                        end
      stop(project, branch)
    when 'start'
      project, branch = if args.first
                          Kyb::Parser.parse(args.shift)
                        elsif (detected = Kyb::Parser.auto_detect)
                          detected
                        else
                          Kyb.die("start requires a project-branch")
                        end
      start(project, branch)
    when 'rm'
      force = args.delete('--force') ? true : false
      project, branch = if args.first
                          Kyb::Parser.parse(args.shift)
                        elsif (detected = Kyb::Parser.auto_detect)
                          detected
                        else
                          Kyb.die("rm requires a project-branch")
                        end
      rm(project, branch, force: force)
    when 'prune'
      prune
    when 'did'
      did(args)
    when 'assert'
      assert_cmd(args)
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
    when 'session'
      Kyb.die("Usage: kyb session wrap <cli> [args...]") unless args.first == 'wrap' && args.size >= 2
      session_wrap(args[1], args[2..])
    when 'notify'
      Kyb.die("Usage: kyb notify <done|blocked|urgent> <message>\n" \
               "  done:    task complete. ALWAYS notify when done\n" \
               "  blocked: need human intervention. Describe what's blocking\n" \
               "  urgent:  confirm before external actions. Describe what you're about to do") if args.empty? || args.size < 2
      level = args[0]
      message = args[1..].join(' ')
      Kyb.die("level must be done/blocked/urgent, got: #{level}") unless %w[done blocked urgent].include?(level)
      notify(level, message)
    when 'version', '--version', '-v'
      puts Kyb.version_string
    when 'help', '--help', '-h'
      help
    else
      help
    end
  end

  def preflight
    if Kyb.in_container?
      puts "preflight 命令不应在容器内运行"
      exit 1
    end
    Kyb::Config.load_config
    Kyb::Check.run_checks
  end

  def help
    puts <<~EOF
      kyb — kubernate your branches 可以不 ／人◕ ‿‿ ◕人＼

      Usage:  kyb COMMAND

      Commands:
        doctor [--prune]                 Scan containers/volumes, clean stale resources
        onboard [--auto]                 Interactive new-user setup wizard
        preflight                        Run pre-flight environment checks (proxy, mirrors, disk)
                                         Run before build to catch network issues early
        build                            Build base image
                                         Run kyb preflight first to check network

        init [NAME] [--port PORT] [--symlink PATH] [--env-template FILE]
                                         Add current project to config
        create PROJECT-BRANCH [--clone] [--ports HOST:CONTAINER] [--model flash|pro]
                                         Create and start a container (--clone: isolated git clone)
        ps, ls                           List containers
        enter PROJECT-BRANCH [--cli claude|kimi|bash]
                                         Enter container (default: claude)
        exec  PROJECT-BRANCH [CMD...]    Run command in container
        stop  PROJECT-BRANCH             Stop container
        start PROJECT-BRANCH             Start stopped container
        rm    PROJECT-BRANCH [--force]   Remove container (--force skips confirmation)
        prune                            Remove all containers
        assert <type> [args...]          Verify and auto-heal prerequisites
                                         Types: java [v], pg, mise <tool>
        did create <name>               DID: create container (Docker-in-Docker)
        did rm <name>                   DID: remove container
        did ps, ls                      DID: list containers
        tts {start|stop|speak...}        macOS TTS controls
        notify <done|blocked|urgent> <message>
                                         Send TTS notification
                                         done=task complete, blocked=need help,
                                         urgent=confirm before action
        session wrap <cli> [args...]    Wrap CLI command with session tracking
        version                          Show version

    EOF
  end
end

require_relative 'cli/build'
require_relative 'cli/init'
require_relative 'cli/create'
require_relative 'cli/enter'
require_relative 'cli/manage'
require_relative 'cli/tts'
require_relative 'cli/did'
require_relative 'cli/session'
require_relative 'cli/assert'
require_relative 'cli/doctor'
require_relative 'cli/onboard'
