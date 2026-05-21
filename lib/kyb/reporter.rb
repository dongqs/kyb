# frozen_string_literal: true

require 'net/http'
require 'json'

module Kyb::Reporter
  CLICKHOUSE_HOST = ENV.fetch('CLICKHOUSE_HOST', 'host.orb.internal')
  CLICKHOUSE_PORT = ENV.fetch('CLICKHOUSE_PORT', '8123').to_i
  CLICKHOUSE_DB = ENV.fetch('CLICKHOUSE_DB', 'kyb')
  METRICS_TABLE = 'metrics'
  SESSIONS_TABLE = 'sessions'

  module_function

  def enabled?
    Kyb::Config.reporting_enabled?
  end

  def emit(event_type, data = {})
    return unless enabled?
    row = {
      timestamp: Time.now.utc.strftime('%Y-%m-%d %H:%M:%S'),
      event: event_type.to_s,
      hostname: Socket.gethostname,
      pid: Process.pid,
      data: data
    }
    http_post("/?query=INSERT INTO #{CLICKHOUSE_DB}.#{METRICS_TABLE} FORMAT JSONEachRow",
              JSON.generate(row))
  rescue => e
    warn "kyb/reporter: #{e.class.name}: #{e.message}"
  end

  def emit_build_duration(duration:, success:, project: nil)
    emit(:kyb_build_duration, { duration_seconds: duration, success: success, project: project })
  end

  def emit_create_event(container:, project:, branch: nil, model: nil)
    emit(:kyb_create_count, { container_id: container, project: project, branch: branch, model: model })
    emit_session_create(container, project, branch, model)
  end

  def emit_rm_event(container:, duration: nil, exit_code: nil)
    emit(:kyb_rm_count, { container_id: container, duration_seconds: duration, exit_code: exit_code })
    emit_session_destroy(container, duration, exit_code)
  end

  def emit_container_count(count:)
    emit(:kyb_container_count, { count: count })
  end

  def emit_preflight_result(check_name:, ok:, duration:, via_proxy: false)
    emit(:kyb_preflight, { check: check_name, ok: ok, duration_seconds: duration, via_proxy: via_proxy })
  end

  def emit_proxy_status(reachable:, proxy:)
    emit(:kyb_proxy_status, { reachable: reachable, proxy: proxy })
  end

  def emit_session_create(container_id, project, branch, model)
    row = {
      timestamp: Time.now.utc.strftime('%Y-%m-%d %H:%M:%S'),
      container_id: container_id, project: project, branch: branch, model: model,
      user: ENV.fetch('USER', 'unknown'), hostname: Socket.gethostname, pid: Process.pid,
      created_at: Time.now.utc.strftime('%Y-%m-%d %H:%M:%S'),
      destroyed_at: nil, duration_seconds: nil, exit_code: nil
    }
    http_post("/?query=INSERT INTO #{CLICKHOUSE_DB}.#{SESSIONS_TABLE} FORMAT JSONEachRow", JSON.generate(row))
  rescue => e
    warn "kyb/reporter: session create: #{e.class.name}: #{e.message}"
  end

  def emit_session_destroy(container_id, duration, exit_code)
    row = {
      timestamp: Time.now.utc.strftime('%Y-%m-%d %H:%M:%S'),
      container_id: container_id,
      destroyed_at: Time.now.utc.strftime('%Y-%m-%d %H:%M:%S'),
      duration_seconds: duration, exit_code: exit_code
    }
    http_post("/?query=INSERT INTO #{CLICKHOUSE_DB}.#{SESSIONS_TABLE} FORMAT JSONEachRow", JSON.generate(row))
  rescue => e
    warn "kyb/reporter: session destroy: #{e.class.name}: #{e.message}"
  end

  def http_post(path, body)
    http = Net::HTTP.new(CLICKHOUSE_HOST, CLICKHOUSE_PORT)
    http.open_timeout = 3
    http.read_timeout = 3
    request = Net::HTTP::Post.new(path)
    request.body = body
    request['Content-Type'] = 'application/json'
    response = http.request(request)
    unless response.is_a?(Net::HTTPOK)
      warn "kyb/reporter: ClickHouse responded #{response.code}: #{response.body}"
    end
  rescue => e
    warn "kyb/reporter: HTTP error: #{e.class.name}: #{e.message}"
  end
end
