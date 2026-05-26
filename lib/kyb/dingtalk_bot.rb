# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Kyb
  module DingtalkBot
    class ConfigError < StandardError; end
    class ApiError < StandardError; end

    WEBHOOK_BASE = 'https://oapi.dingtalk.com/robot/send'

    # === 配置 ===

    def self.webhook_url
      token = ENV['DINGTALK_BOT_TOKEN']
      raise ConfigError, 'DINGTALK_BOT_TOKEN not set' unless token && !token.empty?
      "#{WEBHOOK_BASE}?access_token=#{token}"
    end

    # === 消息发送 ===

    # 发送纯文本消息
    #   text: 消息内容
    #   at_mobiles: @指定手机号列表
    #   at_all: 是否@所有人
    def self.send_text(text, at_mobiles: [], at_all: false)
      post(build_text_payload(text, at_mobiles: at_mobiles, at_all: at_all))
    end

    # 发送 Markdown 消息
    #   title: 标题（必填，显示在消息卡片上）
    #   text: Markdown 正文
    #   at_mobiles: @指定手机号列表
    #   at_all: 是否@所有人
    def self.send_markdown(title, text, at_mobiles: [], at_all: false)
      post(build_markdown_payload(title, text, at_mobiles: at_mobiles, at_all: at_all))
    end

    # === Payload 构建（公开以便测试） ===

    def self.build_text_payload(text, at_mobiles: [], at_all: false)
      {
        msgtype: 'text',
        text: { content: text },
        at: { atMobiles: at_mobiles, isAtAll: at_all },
      }
    end

    def self.build_markdown_payload(title, text, at_mobiles: [], at_all: false)
      {
        msgtype: 'markdown',
        markdown: { title: title, text: text },
        at: { atMobiles: at_mobiles, isAtAll: at_all },
      }
    end

    # === 通知等级 ===

    LEVEL_COLORS = {
      'done'    => '#00BB00',
      'blocked' => '#FF8800',
      'urgent'  => '#FF0000',
    }.freeze

    LEVEL_LABELS = {
      'done'    => '✅ 完成',
      'blocked' => '⚠️ 阻塞',
      'urgent'  => '🚨 紧急',
    }.freeze

    LEVEL_HEADERS = {
      'done'    => '# 任务完成',
      'blocked' => '# 需要干预',
      'urgent'  => '# 紧急确认',
    }.freeze

    def self.notify(level, message, details: nil)
      header = LEVEL_HEADERS.fetch(level, '# 通知')
      label = LEVEL_LABELS.fetch(level, level)
      color = LEVEL_COLORS.fetch(level, '#333333')
      ts = Time.now.strftime('%Y-%m-%d %H:%M:%S')

      md = <<~MD
        #{header}

        > **#{label}** — #{ts}

        #{message}
      MD

      if details
        md += "\n---\n#{details}\n"
      end

      md += "\n> *kyb infra · #{Socket.gethostname}*"

      send_markdown("[#{level}] #{message}", md)
    rescue ConfigError => e
      $stderr.puts "[dingtalk-bot] Config: #{e.message}"
      nil
    end

    # === HTTP 客户端 ===

    def self.post(payload)
      uri = URI.parse(webhook_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 15

      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(payload)

      resp = http.request(req)
      data = JSON.parse(resp.body)

      unless data['errcode'] == 0
        raise ApiError, "errcode=#{data['errcode']} errmsg=#{data['errmsg']}"
      end

      data
    end
  end
end
