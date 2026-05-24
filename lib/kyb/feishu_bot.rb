# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Kyb
  module FeishuBot
    class ConfigError < StandardError; end

    KNOWN_USERS = {
      'ou_75b1fec6d3c2ae67ca1a65fea92a79f0' => 'Aoyama',
    }.freeze

    BOT_SENDER_ID = 'cli_aa9be3a17d3adbeb'
    FEISHU_API = 'https://open.feishu.cn/open-apis'

    # === 配置 ===

    def self.load_config
      app_id = ENV['FEISHU_APP_ID']
      app_secret = ENV['FEISHU_APP_SECRET']
      raise ConfigError, 'FEISHU_APP_ID not set' unless app_id && !app_id.empty?
      raise ConfigError, 'FEISHU_APP_SECRET not set' unless app_secret && !app_secret.empty?
      {
        app_id: app_id,
        app_secret: app_secret,
        chat_id: ENV.fetch('FEISHU_CHAT_ID', 'oc_9b1a09bbdd80887acd63cc02626618c6'),
        poll_interval: (ENV.fetch('FEISHU_POLL_INTERVAL', '5').to_i),
      }
    end

    # === 消息解析 ===

    def self.parse_content(msg)
      return nil unless msg['msg_type'] == 'text'
      raw = msg.dig('body', 'content')
      return nil unless raw
      JSON.parse(raw)['text']
    rescue JSON::ParserError
      nil
    end

    def self.mentioned?(text)
      return false if text.nil? || text.empty?
      text.include?('@_user_1') || text.include?('@kyb-infra')
    end

    def self.bot_message?(msg)
      msg.dig('sender', 'id') == BOT_SENDER_ID
    end

    # === 重试退避 ===

    def self.with_retry(max_attempts: 3, base_delay: 0.5, retryable: [StandardError])
      max_attempts.times do |attempt|
        begin
          return yield
        rescue *retryable => e
          raise e if attempt == max_attempts - 1
          sleep(base_delay * (2 ** attempt))
        end
      end
    end

    # === 已读消息去重 ===

    class SeenTracker
      def initialize(max_size: 500)
        @max_size = max_size
        @seen = []
      end

      def seen?(msg_id)
        @seen.include?(msg_id)
      end

      def mark(msg_id)
        @seen << msg_id
        @seen.shift if @seen.size > @max_size
      end
    end

    # === Feishu API Client ===

    class Client
      def initialize(config)
        @config = config
        @token = nil
        @token_expires_at = 0
        @proxy_uri = ENV.fetch('ALL_PROXY', ENV.fetch('HTTPS_PROXY', nil))
      end

      def get_token
        if Time.now.to_i < @token_expires_at - 60
          return @token
        end

        uri = URI("#{FEISHU_API}/auth/v3/tenant_access_token/internal")
        http = build_http(uri)
        req = Net::HTTP::Post.new(uri)
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate({ app_id: @config[:app_id], app_secret: @config[:app_secret] })

        resp = http.request(req)
        data = JSON.parse(resp.body)
        raise "Token error: #{data['msg']}" unless data['code'] == 0

        @token = data['tenant_access_token']
        @token_expires_at = Time.now.to_i + data['expire'].to_i
        @token
      end

      def fetch_messages(since_msg_id: nil)
        token = get_token
        params = {
          'container_id_type' => 'chat',
          'container_id' => @config[:chat_id],
          'page_size' => '50',
          'sort_type' => 'ByCreateTimeDesc',
        }

        uri = URI("#{FEISHU_API}/im/v1/messages")
        uri.query = URI.encode_www_form(params)
        http = build_http(uri)
        req = Net::HTTP::Get.new(uri)
        req['Authorization'] = "Bearer #{token}"

        resp = http.request(req)
        data = JSON.parse(resp.body)
        raise "Fetch error: #{data['msg']}" unless data['code'] == 0

        items = data.dig('data', 'items') || []
        # Filter out already-seen messages
        if since_msg_id
          items = items.take_while { |m| m['message_id'] != since_msg_id }
                       .reverse
        end
        items
      end

      def send_message(chat_id, text)
        token = get_token
        uri = URI("#{FEISHU_API}/im/v1/messages?receive_id_type=chat_id")
        http = build_http(uri)
        req = Net::HTTP::Post.new(uri)
        req['Authorization'] = "Bearer #{token}"
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate({
          receive_id: chat_id,
          msg_type: 'text',
          content: JSON.generate({ text: text }),
        })

        resp = http.request(req)
        data = JSON.parse(resp.body)
        raise "Send error: #{data['msg']}" unless data['code'] == 0
        data
      end

      private

      def build_http(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 10
        http.read_timeout = 15
        if @proxy_uri
          proxy = URI.parse(@proxy_uri)
          if proxy.scheme == 'socks5'
            http.instance_variable_set(:@proxy_addr, proxy.host)
            http.instance_variable_set(:@proxy_port, proxy.port)
          end
        end
        http
      end
    end

    # === 主循环 ===

    class Runner
      MAX_MSG_LEN = 2000
      RATE_WINDOW = 30
      RATE_MAX = 5

      def initialize(config)
        @config = config
        @client = Client.new(config)
        @seen = SeenTracker.new
        @ck = CkLogger.new
        @health = { poll_count: 0, error_count: 0, consecutive_failures: 0, last_success: nil }
        @rate_limit = {}
        $stdout.sync = true
      end

      def rate_limited?(sender)
        now = Time.now.to_i
        @rate_limit[sender] ||= []
        @rate_limit[sender].reject! { |t| now - t > RATE_WINDOW }
        return true if @rate_limit[sender].size >= RATE_MAX
        @rate_limit[sender] << now
        false
      end

      def run
        puts '[feishu-bot] 启动'
        puts "[feishu-bot] Chat ID: #{@config[:chat_id]}"
        puts "[feishu-bot] Poll interval: #{@config[:poll_interval]}s"

        # 初次获取 token 验证凭证
        @client.get_token
        @ck.log_event(type: 'bot_start', content: 'feishu-bot started', tags: { chat_id: @config[:chat_id] })
        puts '[feishu-bot] Token 获取成功'

        loop do
          begin
            tick
          rescue Interrupt
            puts "\n[feishu-bot] 收到中断，退出"
            @ck.log_event(type: 'bot_stop', content: 'interrupted')
            break
          rescue StandardError => e
            @health[:error_count] += 1
            @health[:consecutive_failures] += 1
            delay = [2 ** @health[:consecutive_failures], 30].min
            msg = "错误(#{@health[:consecutive_failures]}次连续): #{e.message}"
            puts "[feishu-bot] #{msg}"
            @ck.log_event(type: 'bot_error', content: msg, tags: { consecutive: @health[:consecutive_failures].to_s })
            sleep(delay)
          end
        end
      end

      private

      def tick
        messages = @client.fetch_messages

        messages.each do |msg|
          process_message(msg)
        end

        @health[:poll_count] += 1
        @health[:consecutive_failures] = 0
        @health[:last_success] = Time.now

        # 每 12 次 poll 打一次健康日志 (~1min at 5s interval)
        if @health[:poll_count] % 12 == 0
          msg = "polls=#{@health[:poll_count]} errors=#{@health[:error_count]}"
          puts "[feishu-bot] ♥ #{msg}"
          @ck.log_event(type: 'heartbeat', content: msg, tags: {
            poll_count: @health[:poll_count].to_s, error_count: @health[:error_count].to_s
          })
        end

        sleep(@config[:poll_interval])
      end

      def process_message(msg)
        msg_id = msg['message_id']
        return if @seen.seen?(msg_id)
        @seen.mark(msg_id)

        # 跳过 bot 自己发的
        return if Kyb::FeishuBot.bot_message?(msg)

        text = Kyb::FeishuBot.parse_content(msg)
        return unless text

        sender = msg.dig('sender', 'id') || '?'
        sender_name = KNOWN_USERS.fetch(sender, sender[0..15])

        # 长度限制
        if text.length > MAX_MSG_LEN
          text = text[0, MAX_MSG_LEN]
          puts ">>> [#{sender_name}]: (消息超长，截断至 #{MAX_MSG_LEN} 字)"
        end

        # 限流: 同一发送者 30s 内最多 5 条
        if rate_limited?(sender)
          @ck.log_event(type: 'message_dropped', content: 'rate limited', tags: { sender: sender })
          return
        end

        is_mention = Kyb::FeishuBot.mentioned?(text)
        event_type = is_mention ? 'message_mention' : 'message_new'
        puts ">>> [#{sender_name}]: #{text[0..200]}"
        @ck.log_event(type: event_type, content: text, tags: { sender: sender, sender_name: sender_name, mentioned: is_mention.to_s })

        # 全部消息都通知——外部内容不入会话（防注入）
        puts ""
        puts "╔══ 飞书通知 ════════════════════════"
        puts "║ 飞书有新消息请查收"
        puts "║ 详情见: /tmp/feishu-bot.log"
        puts "║ 日志CK: kyb.agent_events"
        puts "╚════════════════════════════════════"
        puts ""

      end
    end

    # === ClickHouse 日志 ===

    class CkLogger
      CK_HOST = ENV.fetch('CLICKHOUSE_HOST', 'host.orb.internal')
      CK_PORT = ENV.fetch('CLICKHOUSE_PORT', '8123').to_i
      TABLE = 'kyb.agent_events'

      def initialize
        @http = Net::HTTP.new(CK_HOST, CK_PORT)
        @http.open_timeout = 3
        @http.read_timeout = 5
      end

      def log_event(type:, content:, tags: {})
        ts = Time.now.utc.strftime('%Y-%m-%d %H:%M:%S')
        query = <<~SQL
          INSERT INTO #{TABLE} (timestamp, agent_id, session_id, project, event_type, content, tags)
          VALUES ('#{ts}', 'feishu-bot', '#{session_id}', 'kyb', '#{esc(type)}', '#{esc(content)}', #{tags_str(tags)})
        SQL
        req = Net::HTTP::Post.new('/')
        req.body = query
        req['Content-Type'] = 'text/plain'
        @http.request(req)
      rescue StandardError => e
        # CK 不可用时不能影响 bot 主流程，只打日志
        $stderr.puts "[feishu-bot] CK log error: #{e.message}"
      end

      private

      def session_id
        @session_id ||= ENV.fetch('KYB_SESSION_ID', "feishu-bot-#{Process.pid}")
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

# === CLI ===
if __FILE__ == $PROGRAM_NAME
  config = Kyb::FeishuBot.load_config
  Kyb::FeishuBot::Runner.new(config).run
end
