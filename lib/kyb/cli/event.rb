# frozen_string_literal: true

module Kyb::CLI
  module_function

  def event_cmd(args)
    subcmd = args.first
    case subcmd
    when 'dispatch'
      event_dispatch(args[1..])
    when 'complete'
      event_complete(args[1..])
    when 'heartbeat'
      event_heartbeat
    else
      event_help
    end
  end

  def event_dispatch(rest)
    Kyb.die("Usage: kyb event dispatch <task_type> <target>") unless rest.size >= 2
    task_type, target = rest[0], rest[1]
    Kyb::Reporter.emit_dispatch(task_type: task_type, target: target)
    puts "Event dispatched: #{task_type} -> #{target}"
  end

  def event_complete(rest)
    Kyb.die("Usage: kyb event complete <task_type> <duration> <outcome>") unless rest.size >= 3
    task_type, duration_str, outcome = rest[0], rest[1], rest[2]
    Kyb::Reporter.emit_complete(task_type: task_type, duration: duration_str.to_f, outcome: outcome)
    puts "Event completed: #{task_type} (#{outcome}) in #{duration_str}s"
  end

  def event_heartbeat
    container_count = Kyb::Docker.ps_list.size rescue 0
    disk = begin
      out = `df -h / 2>/dev/null`.lines[1]
      out ? out.split[4] : 'unknown'
    rescue
      'unknown'
    end
    mem = begin
      out = `free -h 2>/dev/null`.lines[1]
      out ? "#{out.split[2]}/#{out.split[1]}" : 'unknown'
    rescue
      'unknown'
    end
    Kyb::Reporter.emit_heartbeat(container_count: container_count, disk: disk, mem: mem)
    puts "Heartbeat: #{container_count} containers, disk #{disk}, mem #{mem}"
  end

  def event_help
    puts <<~HELP
      kyb event — manual event logging

      Automatically recorded events:
        container_create   On kyb create
        container_rm       On kyb rm
        session_start      On kyb enter
        exec               On kyb exec
        session_complete   On session wrap exit

      Manual events (agent-driven):
        dispatch           kyb event dispatch <task_type> <target>
        complete           kyb event complete <task_type> <duration> <outcome>
        heartbeat          kyb event heartbeat
    HELP
  end
end
