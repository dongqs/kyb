# frozen_string_literal: true

module Kyb::CLI
  module_function

  def onboard(args = [])
    if args.include?('--auto')
      onboard_auto
    else
      onboard_interactive
    end
  end

  def onboard_auto
    puts '==> kyb onboard (auto mode)'
    onboard_ensure_kyb_dir
    add_to_path
    onboard_build
    onboard_add_project(true)
    onboard_create_and_enter(true)
    puts "\n==> Onboard complete! Run 'kyb' to get started."
  end

  def onboard_interactive
    puts '==> kyb onboard (interactive wizard)'
    puts "\nWelcome to kyb!"
    onboard_interactive_kyb_dir
    onboard_interactive_path
    onboard_build
    onboard_add_project(false)
    onboard_create_and_enter(false)
    puts "\n==> Onboard complete!"
  end

  def onboard_ensure_kyb_dir
    kyb_dir = File.expand_path('~/.kyb')
    if File.directory?(kyb_dir)
      puts "  [SKIP] ~/.kyb already exists"
      return
    end
    puts '==> Step 1: Cloning ~/.kyb'
    system('git', 'clone', 'https://git.leyantech.com/quick-n-dirty/kyb.git', kyb_dir) || begin
      puts '  Trying SSH fallback...'
      system('git', 'clone', 'git@git.leyantech.com:quick-n-dirty/kyb.git', kyb_dir) || begin
        puts '  Trying local copy...'
        FileUtils.mkdir_p(kyb_dir)
      end
    end
    puts "  [OK] ~/.kyb ready"
  end

  def onboard_interactive_kyb_dir
    kyb_dir = File.expand_path('~/.kyb')
    if File.directory?(kyb_dir)
      puts "  [SKIP] ~/.kyb already exists"
      return
    end
    puts 'Step 1: Clone ~/.kyb'
    print '  Clone the kyb repo? [Y/n] '
    ans = $stdin.gets.to_s.strip.downcase
    return if ans == 'n' || ans == 'no'
    onboard_ensure_kyb_dir
  end

  def add_to_path
    rc_file = shell_rc_file
    return unless File.exist?(rc_file)
    content = File.read(rc_file)
    export_line = 'export PATH="$HOME/.kyb/bin:$PATH"'
    if content.include?(export_line)
      puts "  [SKIP] PATH already configured"
      return
    end
    File.open(rc_file, 'a') { |f| f.puts "\n#{export_line}" }
    puts "  [OK] Added kyb to PATH"
    puts "       Run: source #{rc_file}"
  end

  def shell_rc_file
    shell = ENV['SHELL'] || '/bin/bash'
    case File.basename(shell)
    when 'zsh' then File.expand_path('~/.zshrc')
    when 'fish' then File.expand_path('~/.config/fish/config.fish')
    else File.expand_path('~/.bashrc')
    end
  end

  def onboard_interactive_path
    puts "\nStep 2: Add kyb to PATH"
    puts "  Detected shell: #{File.basename(ENV['SHELL'] || 'bash')}"
    print '  Add to PATH? [Y/n] '
    ans = $stdin.gets.to_s.strip.downcase
    return if ans == 'n' || ans == 'no'
    add_to_path
  end

  def onboard_build
    puts "\nStep 3: Build base image"
    puts '  Running: kyb build'
    Kyb::Config.load_config
    path = Kyb::Config.base_image_path
    dockerfile = File.join(path, 'Dockerfile')
    unless File.exist?(dockerfile)
      puts '  [SKIP] Dockerfile not found'
      return
    end
    proxy = Kyb::Proxy.detect
    Kyb::Docker.build(Kyb::Container::BASE_IMAGE, path, proxy: proxy)
    puts '  [OK] Base image built'
  rescue => e
    puts "  [FAIL] Build failed: #{e.message}"
  end

  def onboard_add_project(auto)
    puts "\nStep 4: Add a project"
    projects = Kyb::Config.project_names rescue []
    if projects.any?
      puts "  Existing projects: #{projects.join(', ')}"
      print auto ? "  [AUTO] Skip\n" : '  Add another? [y/N] '
      unless auto
        ans = $stdin.gets.to_s.strip.downcase
        return unless ans == 'y' || ans == 'yes'
      else
        return
      end
    end
    cwd = Dir.pwd
    detected = nil
    if system('git', 'rev-parse', '--show-toplevel', out: File::NULL, err: File::NULL)
      detected = File.basename(cwd)
      puts "  Detected project: #{detected}"
    end
    if auto
      return unless detected
      project_name = detected
    else
      print '  Project name: '
      project_name = $stdin.gets.to_s.strip
      project_name = detected if project_name.empty? && detected
      return if project_name.empty?
    end
    data = { 'path' => cwd, 'base_branch' => 'master' }
    Kyb::Config.save(project_name, data)
    puts "  [OK] Project '#{project_name}' added to config"
  end

  def onboard_create_and_enter(auto)
    puts "\nStep 5: Create sandbox"
    projects = Kyb::Config.project_names rescue []
    return if projects.empty?
    project = projects.first
    branch = 'kyb'
    if auto
      puts "  [AUTO] Creating sandbox: #{project}-#{branch}"
    else
      print "  Create sandbox for #{project}? [Y/n] "
      ans = $stdin.gets.to_s.strip.downcase
      return if ans == 'n' || ans == 'no'
    end
    container, _ports = Kyb::Docker.create_container(project, branch)
    puts '  [OK] Sandbox created'
  rescue => e
    puts "  [FAIL] #{e.message}"
  end
end
