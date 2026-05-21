# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'socket'
require 'delegate'
require 'net/http'
require 'uri'
require 'open3'

module Kyb
  VERSION = '0.10.0'

  ALIASES = %w[
    可以不
    可以吧
    不可以？
    可以嘛
    可以哟
    可以的
    可以可以
    可以啊
    很可以
    太可以
    不太可以
    不可以太
    狠不可以
    可不可以
    可可以以
    合意味
    和味道
    可以太
    大可以
    斯阔以
  ].freeze

  def self.version_string
    "kyb #{VERSION} (／人◕ ‿‿ ◕人＼ #{ALIASES.sample})"
  end

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

  CLONE_BASE = File.expand_path('~/.local/share/kyb/clones')

  GRADLE_CACHE_VOLUME = 'kyb-gradle-cache'
  MAVEN_CACHE_VOLUME = 'kyb-maven-cache'

  module_function

  def die(msg)
    warn "ERROR: #{msg}"
    raise SystemExit, 1
  end

  def in_container?
    File.exist?('/.dockerenv')
  end

  def enable_profile
    $stdout = TimestampedOutput.new($stdout)
  end
end

require_relative 'kyb/config'
require_relative 'kyb/check'
require_relative 'kyb/proxy'
require_relative 'kyb/container'
require_relative 'kyb/parser'
require_relative 'kyb/docker'
require_relative 'kyb/reporter'
require_relative 'kyb/worldview'
require_relative 'kyb/cli'
