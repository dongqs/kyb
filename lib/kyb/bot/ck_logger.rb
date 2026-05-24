# frozen_string_literal: true

module Kyb
  module Bot
    # ClickHouse 事件日志
    class CkLogger
      CK_HOST = ENV.fetch('CLICKHOUSE_HOST', 'host.orb.internal')
      CK_PORT = ENV.fetch('CLICKHOUSE_PORT', '8123').to_i
      TABLE = 'kyb.agent_events'

      def initialize(agent_id: 'feishu-bot', project: 'kyb')
        @agent_id = agent_id
        @project = project
        @http = Net::HTTP.new(CK_HOST, CK_PORT)
        @http.open_timeout = 3
        @http.read_timeout = 5
      end

      def log_event(type:, content:, tags: {})
        ts = Time.now.utc.strftime('%Y-%m-%d %H:%M:%S')
        query = <<~SQL
          INSERT INTO #{TABLE} (timestamp, agent_id, session_id, project, event_type, content, tags)
          VALUES ('#{ts}', '#{esc(@agent_id)}', '#{esc(session_id)}', '#{esc(@project)}', '#{esc(type)}', '#{esc(content)}', #{tags_str(tags)})
        SQL
        req = Net::HTTP::Post.new('/')
        req.body = query
        req['Content-Type'] = 'text/plain'
        @http.request(req)
      rescue StandardError => e
        $stderr.puts "[#{@agent_id}] CK log error: #{e.message}"
      end

      private

      def session_id
        @session_id ||= ENV.fetch('KYB_SESSION_ID', "#{@agent_id}-#{Process.pid}")
      end

      def esc(str)
        str.to_s.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }
      end

      def tags_str(hash)
        "{#{hash.map { |k, v| "'#{esc(k.to_s)}':'#{esc(v.to_s)}'" }.join(',')}}"
      end
    end
  end
end
