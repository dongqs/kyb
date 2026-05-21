# frozen_string_literal: true

module Kyb::CLI
  module_function

  def assert_usage
    puts "kyb assert -- Verify and auto-heal environment prerequisites\n\n"
    puts "Usage: kyb assert <type> [args...]\n\n"
    puts "Types:"
    puts "  java [version]    Verify/install JDK (default: 21)"
    puts "  pg                Verify/start PostgreSQL"
    puts "  mise <tool>       Verify/install mise-managed tool (mvn, gradle, ...)"
  end

  def assert_cmd(args)
    if args.empty?
      assert_usage
      return
    end

    type = args.shift
    case type
    when 'java'
      version = args.first || '21'
      exit 1 unless Kyb::Check.assert_java(expected_version: version)
    when 'pg'
      exit 1 unless Kyb::Check.assert_pg
    when 'mise'
      Kyb.die("Usage: kyb assert mise <tool>") if args.empty?
      exit 1 unless Kyb::Check.assert_mise_tool(args.first)
    when 'help', '--help', '-h'
      assert_usage
    else
      Kyb.die("Unknown assert type: #{type}. Known: java, pg, mise")
    end
  end
end
