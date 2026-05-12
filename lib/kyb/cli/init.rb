# frozen_string_literal: true

module Kyb::CLI
  module_function

  def init(args = [])
    unless system('git', 'rev-parse', '--show-toplevel', out: File::NULL)
      Kyb.die('not in a git repository — run from a project root')
    end
    name = File.basename(Dir.pwd)
    home = Dir.home
    cwd = Dir.pwd
    path = cwd.start_with?(home) ? cwd.sub(home, '~') : cwd

    base_branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
    base_branch = 'master' if base_branch.empty?

    symlinks = []
    ports = []
    idx = 0
    while idx < args.size
      case args[idx]
      when '--port'
        ports << args[idx + 1] if args[idx + 1]
        idx += 2
      when '--symlink'
        symlinks << args[idx + 1] if args[idx + 1]
        idx += 2
      when '--env-template'
        env_template = args[idx + 1]
        idx += 2
      else
        name = args[idx] unless args[idx].start_with?('--')
        idx += 1
      end
    end

    data = { 'path' => path, 'base_branch' => base_branch }
    data['ports'] = ports unless ports.empty?
    data['symlinks'] = symlinks unless symlinks.empty?
    data['env_template'] = env_template if env_template

    if File.exist?(Kyb::CONFIG_FILE)
      existing = YAML.safe_load_file(Kyb::CONFIG_FILE, permitted_classes: [Symbol])
      if existing['projects']&.key?(name)
        puts "==> #{name} already exists in #{Kyb::CONFIG_FILE}, updating..."
      end
    end

    Kyb::Config.save(name, data)
    puts "==> #{name} added to #{Kyb::CONFIG_FILE}  (◕‿‿◕)"
    puts "    path: #{path}"
    puts "    base_branch: #{base_branch}"
    puts "    ports: #{ports.join(', ')}" unless ports.empty?
    puts "    symlinks: #{symlinks.join(', ')}" unless symlinks.empty?
    puts "    env_template: #{env_template}" if env_template
  end
end
