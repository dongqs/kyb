# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'socket'
require 'delegate'

module Kyb
  VERSION = '0.5.31'

  class TimestampedOutput < SimpleDelegator
    def puts(*args)
      if args.empty?
        __getobj__.puts
      else
        ts = Time.now.strftime('[%H:%M:%S]')
        args.each { |arg| __getobj__.puts "#{ts} #{arg}" }
      end
    end

    def print(*args)
      ts = Time.now.strftime('[%H:%M:%S]')
      __getobj__.print "#{ts} #{args.join}"
    end

    def printf(*args)
      ts = Time.now.strftime('[%H:%M:%S]')
      __getobj__.print "#{ts} "
      __getobj__.printf(*args)
    end
  end
  CONFIG_FILE = File.expand_path('~/.config/kyb/config.yml')

  WORKTREE_BASE = File.expand_path('~/.kyb/worktrees')

  module_function

  def die(msg)
    warn "ERROR: #{msg}"
    exit 1
  end

  def enable_profile
    $stdout = TimestampedOutput.new($stdout)
  end
end

require_relative 'kyb/config'
require_relative 'kyb/container'
require_relative 'kyb/parser'
require_relative 'kyb/docker'
require_relative 'kyb/git'
require_relative 'kyb/cli'
