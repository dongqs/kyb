# frozen_string_literal: true

require_relative 'test_helper'

class OnboardTest < Minitest::Test
  def setup
    require_relative '../lib/kyb/cli/onboard'
    @home_backup = ENV.fetch('HOME', nil)
    ENV['HOME'] = '/tmp/test_kyb_home'
    FileUtils.mkdir_p('/tmp/test_kyb_home')
  end

  def teardown
    FileUtils.rm_rf('/tmp/test_kyb_home')
    ENV['HOME'] = @home_backup if @home_backup
  end

  def test_shell_rc_bash
    orig = ENV.fetch('SHELL', nil); ENV['SHELL'] = '/bin/bash'
    assert_match(/\.bashrc$/, Kyb::CLI.shell_rc_file)
  ensure ENV['SHELL'] = orig end

  def test_shell_rc_zsh
    orig = ENV.fetch('SHELL', nil); ENV['SHELL'] = '/bin/zsh'
    assert_match(/\.zshrc$/, Kyb::CLI.shell_rc_file)
  ensure ENV['SHELL'] = orig end

  def test_shell_rc_fish
    orig = ENV.fetch('SHELL', nil); ENV['SHELL'] = '/usr/bin/fish'
    assert_match(/\.config\/fish\/config\.fish$/, Kyb::CLI.shell_rc_file)
  ensure ENV['SHELL'] = orig end

  def test_shell_rc_default
    orig = ENV.fetch('SHELL', nil); ENV.delete('SHELL')
    assert_match(/\.bashrc$/, Kyb::CLI.shell_rc_file)
  ensure ENV['SHELL'] = orig end

  def test_path_added
    File.write("#{ENV['HOME']}/.bashrc", "# existing\n")
    orig = ENV.fetch('SHELL', nil); ENV['SHELL'] = '/bin/bash'
    Kyb::CLI.add_to_path
    result = File.read("#{ENV['HOME']}/.bashrc")
    assert_match(/kyb/, result)
  ensure ENV['SHELL'] = orig end

  def test_path_duplicate
    File.write("#{ENV['HOME']}/.bashrc", "\nexport PATH=\"$HOME/.kyb/bin:$PATH\"\n")
    orig = ENV.fetch('SHELL', nil); ENV['SHELL'] = '/bin/bash'
    content = File.read("#{ENV['HOME']}/.bashrc")
    Kyb::CLI.add_to_path
    assert_equal content, File.read("#{ENV['HOME']}/.bashrc")
  ensure ENV['SHELL'] = orig end
end
