# frozen_string_literal: true

require 'net/http'
require 'socket'

module Kyb::CLI
  module_function

  MORNING_HEADER = <<~BOX
    ╔══════════════════════════════════════════════╗
    ║              ／人◕ ‿‿ ◕人＼                    ║
    ║               Good Morning                   ║
    ╚══════════════════════════════════════════════╝
  BOX

  def morning(_args = [])
    puts MORNING_HEADER
    puts
    morning_print_whoami
    puts
    morning_print_whereami
    puts
    morning_print_yesterday
    puts
    morning_print_todo
    puts
    morning_print_commands
  end

  def morning_hostname
    Socket.gethostname
  rescue StandardError
    `hostname 2>/dev/null`.strip
  end

  def morning_project
    ENV['KYB_PROJECT']
  end

  def morning_branch
    branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
    branch.empty? ? '(detached)' : branch
  rescue StandardError
    'unknown'
  end

  def morning_user
    ENV['USER'] || `whoami 2>/dev/null`.strip
  rescue StandardError
    'unknown'
  end

  def morning_print_whoami
    puts '── Who am I ──'
    cname = morning_hostname
    proj = morning_project
    cname_str = cname.to_s.empty? ? '(unknown)' : cname
    proj_str = proj ? " (#{proj})" : ''
    puts "  Container: #{cname_str}#{proj_str}"
    puts "  Branch: #{morning_branch}"
    puts "  User: #{morning_user}"
  end

  def morning_git_status_text
    modified = `git status --porcelain 2>/dev/null`.lines.count
    unpushed = `git log --oneline @{u}..HEAD 2>/dev/null`.lines.count
    parts = []
    parts << "#{modified} file(s) modified" if modified.positive?
    parts << "#{unpushed} commit(s) unpushed" if unpushed.positive?
    parts.empty? ? 'clean' : parts.join(', ')
  rescue StandardError
    'n/a'
  end

  def morning_docker_running
    `docker ps -q 2>/dev/null`.lines.count
  rescue StandardError
    0
  end

  def morning_docker_images_size
    `docker system df --format '{{.Size}}' 2>/dev/null`.lines.last.to_s.strip
  rescue StandardError
    ''
  end

  def morning_disk_pct
    `df -h / 2>/dev/null`.lines.last.to_s.split(/\s+/)[4] || ''
  rescue StandardError
    ''
  end

  def morning_pg_ready?
    out = `pg_isready -h localhost -p 5432 2>/dev/null`.strip
    out.include?('accepting connections') || out.include?('ready')
  rescue StandardError
    false
  end

  def morning_ck_table_info
    host = ENV.fetch('CLICKHOUSE_HOST', 'host.orb.internal')
    port = ENV.fetch('CLICKHOUSE_PORT', '8123').to_i
    http = Net::HTTP.new(host, port)
    http.open_timeout = 3
    http.read_timeout = 5
    request = Net::HTTP::Post.new('/')
    request.body = "SELECT count() FROM kyb.agent_events FORMAT TabSeparated"
    request['Content-Type'] = 'text/plain'
    response = http.request(request)
    if response.is_a?(Net::HTTPOK)
      count = response.body.strip
      "kyb.agent_events table ready (#{count} rows)"
    else
      'kyb.agent_events unavailable'
    end
  rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL,
         Net::OpenTimeout, Net::ReadTimeout, SocketError
    'not available (CK not reachable)'
  rescue StandardError => e
    "not available (#{e.message})"
  end

  def morning_proxy_url
    ENV.fetch('KYB_PROXY', nil) || (Kyb::Config.proxy rescue nil)
  end

  def morning_proxy_check(url)
    uri = URI.parse(url)
    sock = TCPSocket.new(uri.host, uri.port)
    sock.close
    true
  rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, SocketError
    false
  rescue StandardError
    false
  end

  def morning_print_whereami
    puts '── Where am I ──'
    puts "  Git: #{morning_git_status_text}"
    running = morning_docker_running
    img_size = morning_docker_images_size
    disk = morning_disk_pct
    docker_parts = ["#{running} container(s) running"]
    docker_parts << "#{img_size} images" unless img_size.empty?
    docker_parts << "#{disk} disk" unless disk.empty?
    puts "  Docker: #{docker_parts.join(', ')}"
    pg = morning_pg_ready?
    puts "  PG: #{pg ? 'accepting connections @ localhost:5432' : 'not available'}"
    puts "  CK: #{morning_ck_table_info}"
    proxy_url = morning_proxy_url
    if proxy_url
      status = morning_proxy_check(proxy_url) ? 'OK' : 'not reachable'
      puts "  Proxy: #{proxy_url} #{status}"
    else
      puts '  Proxy: not configured'
    end
  end

  def morning_recent_events
    host = ENV.fetch('CLICKHOUSE_HOST', 'host.orb.internal')
    port = ENV.fetch('CLICKHOUSE_PORT', '8123').to_i
    http = Net::HTTP.new(host, port)
    http.open_timeout = 3
    http.read_timeout = 5
    query = "SELECT formatDateTime(timestamp, '%H:%M'), event_type, content " \
            "FROM kyb.agent_events " \
            "WHERE timestamp >= now() - INTERVAL 1 DAY " \
            "ORDER BY timestamp DESC LIMIT 5 FORMAT TabSeparated"
    request = Net::HTTP::Post.new('/')
    request.body = query
    request['Content-Type'] = 'text/plain'
    response = http.request(request)
    if response.is_a?(Net::HTTPOK)
      response.body.lines.map(&:strip).map do |line|
        parts = line.split("\t", 3)
        next if parts.size < 2
        time = parts[0]
        etype = parts[1]
        content = parts[2] || ''
        content = content.length > 60 ? "#{content[0, 60]}..." : content
        "  [#{time}] #{etype}: #{content}"
      end.compact
    else
      []
    end
  rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL,
         Net::OpenTimeout, Net::ReadTimeout, SocketError
    nil
  rescue StandardError
    nil
  end

  def morning_print_yesterday
    puts "── Yesterday's work ──"
    events = morning_recent_events
    if events.nil?
      puts '  (CK unavailable, cannot query recent events)'
    elsif events.empty?
      puts '  (no recent events found in agent_events)'
    else
      events.each { |ev| puts ev }
    end
  rescue StandardError => e
    puts "  (unavailable: #{e.message})"
  end

  def morning_batch_tasks
    batch_file = File.expand_path('../../../working/onboarding-batches.md', __dir__)
    return nil unless File.exist?(batch_file)
    lines = File.readlines(batch_file)
    tasks = []
    current_wave = nil
    lines.each do |line|
      if line =~ /^##\s+(.+)/
        current_wave = $1.strip
      elsif line =~ /^\|\s*\d+\s*\|/
        cols = line.split('|').map(&:strip)
        project = cols[1]
        status = cols[3]
        tasks << "[#{current_wave}] #{project}: #{status}" if project && !project.empty?
      end
    end
    tasks.empty? ? nil : tasks
  rescue StandardError
    nil
  end

  def morning_print_todo
    puts '── What to do ──'
    tasks = morning_batch_tasks
    if tasks
      puts '  Onboarding batches active:'
      tasks.each { |t| puts "    #{t}" }
    else
      puts '  (default) Review code, check tests, push changes, assist with tasks.'
    end
  rescue StandardError
    puts '  (default) Review code, check tests, push changes, assist with tasks.'
  end

  def morning_print_commands
    puts '── Quick commands ──'
    puts '  kyb ps              # List sandboxes'
    puts '  kyb doctor          # Health check'
    puts '  kyb prod ck "..."   # Query collective memory'
    puts '  kyb enter <name>    # Enter sandbox'
  end
end
