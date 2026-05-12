# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'socket'

module Kyb
  VERSION = '0.3.0'
  CONFIG_FILE = File.expand_path('~/.config/kyb/config.yml')
  BASE_IMAGE = 'dev-sandbox-base'
  WORKTREE_BASE = File.expand_path('~/.kyb/worktrees')

  module_function

  def die(msg)
    warn "ERROR: #{msg}"
    exit 1
  end
end

require_relative 'kyb/config'
require_relative 'kyb/docker'
require_relative 'kyb/git'
require_relative 'kyb/cli'
