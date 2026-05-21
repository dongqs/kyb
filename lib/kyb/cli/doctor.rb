# frozen_string_literal: true

module Kyb::CLI
  module_function

  def doctor(args = [])
    prune = args.include?("--prune")
    containers = doctor_scan_containers
    volumes = doctor_scan_volumes(containers)
    doctor_print_report(containers, volumes)
    doctor_cleanup(containers, volumes) if prune
  end

  def doctor_scan_containers
    doctor_ps_raw.map do |name, status|
      { name: name, status: status, alive: doctor_container_tmux_alive?(name) }
    end
  end

  def doctor_scan_volumes(containers)
    all_volumes = doctor_volume_names
    vol_to_containers = {}
    containers.each do |c|
      doctor_container_volumes(c[:name]).each do |vname|
        vol_to_containers[vname] ||= []
        vol_to_containers[vname] << c
      end
    end
    all_volumes.map do |vname|
      is_cache = vname.match?(/\Akyb-.*-cache\z/)
      using = vol_to_containers[vname] || []
      alive_using = using.select { |c| c[:alive] }
      if is_cache
        { name: vname, cache: true, in_use: false, orphan: false }
      elsif alive_using.any?
        { name: vname, cache: false, in_use: true, orphan: false }
      else
        { name: vname, cache: false, in_use: false, orphan: true }
      end
    end
  end

  def doctor_ps_raw
    `docker ps -a --format '{{.Names}}\t{{.Status}}' --filter 'name=kyb-' 2>/dev/null`
      .lines.map { |l| l.strip.split("\t", 2) }
  end

  def doctor_container_tmux_alive?(cname)
    system('docker', 'exec', '-u', 'dev', cname,
           'tmux', 'has-session', '-t', 'dev',
           out: File::NULL, err: File::NULL)
  end

  def doctor_volume_names
    `docker volume ls -q`.lines.map(&:strip)
  end

  def doctor_container_volumes(cname)
    `docker inspect '#{cname}' --format '{{range .Mounts}}{{.Name}} {{end}}' 2>/dev/null`.strip.split
  end

  def doctor_print_report(containers, volumes)
    alive = containers.select { |c| c[:alive] }
    stale = containers.reject { |c| c[:alive] }
    orphans = volumes.select { |v| v[:orphan] }
    puts ""
    puts "容器 (#{containers.size}):"
    containers.each do |c|
      icon = c[:alive] ? "✔" : "✗"
      tmux_info = c[:alive] ? "(tmux: dev)" : "(no tmux)"
      puts "  #{icon} #{c[:name]}  #{tmux_info}  ↑ #{c[:status]}"
    end
    puts ""
    puts "Volume (#{volumes.size}):"
    volumes.each do |v|
      if v[:cache]
        puts "  ✔ #{v[:name]}  (shared cache)"
      elsif v[:in_use]
        puts "  ✔ #{v[:name]}  (in use)"
      elsif v[:orphan]
        puts "  ✗ #{v[:name]}  (orphan)"
      else
        puts "  ✗ #{v[:name]}  (unused)"
      end
    end
    puts ""
    puts "Summary: #{alive.size} alive, #{stale.size} stale, #{orphans.size} orphans"
  end

  def doctor_cleanup(containers, volumes)
    stale = containers.reject { |c| c[:alive] }
    orphans = volumes.select { |v| v[:orphan] }
    stale.each { |c| puts "==> #{c[:name]}: removing stale container"; doctor_stop_and_rm(c[:name]) }
    orphans.each { |v| puts "==> #{v[:name]}: removing orphan volume"; doctor_volume_rm(v[:name]) }
    puts "==> Cleaned: #{stale.size} containers, #{orphans.size} volumes"
  end

  def doctor_stop_and_rm(cname)
    system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
  end

  def doctor_volume_rm(vname)
    system('docker', 'volume', 'rm', vname, out: File::NULL, err: File::NULL)
  end
end
