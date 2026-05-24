# frozen_string_literal: true

module Kyb
  module Bot
    # 通用 Runner：健康循环、错误恢复、心跳日志
    #
    # 平台适配器需实现:
    #   name           → String, 日志用的 agent 名称
    #   fetch_new_items  → Array, 获取新数据（必须返回数组）
    #   process_item(item) → 处理单条数据
    #   on_start       → （可选）启动时调用
    class Runner
      def initialize(adapter, config)
        @adapter = adapter
        @poll_interval = config[:poll_interval] || 5
        @ck = CkLogger.new(agent_id: adapter.name)
        @health = { poll_count: 0, error_count: 0, consecutive_failures: 0, last_success: nil }
        $stdout.sync = true
      end

      def run
        puts "[#{@adapter.name}] 启动"
        @adapter.on_start if @adapter.respond_to?(:on_start)
        @ck.log_event(type: 'bot_start', content: "#{@adapter.name} started")

        loop do
          begin
            tick
          rescue Interrupt
            puts "[#{@adapter.name}] 收到中断，退出"
            @ck.log_event(type: 'bot_stop', content: 'interrupted')
            break
          rescue StandardError => e
            @health[:error_count] += 1
            @health[:consecutive_failures] += 1
            delay = [2 ** @health[:consecutive_failures], 30].min
            msg = "错误(#{@health[:consecutive_failures]}次连续): #{e.message}"
            puts "[#{@adapter.name}] #{msg}"
            @ck.log_event(type: 'bot_error', content: msg, tags: { consecutive: @health[:consecutive_failures].to_s })
            sleep(delay)
          end
        end
      end

      private

      def tick
        (@adapter.fetch_new_items || []).each do |item|
          @adapter.process_item(item)
        end

        @health[:poll_count] += 1
        @health[:consecutive_failures] = 0
        @health[:last_success] = Time.now

        if @health[:poll_count] % 12 == 0
          msg = "polls=#{@health[:poll_count]} errors=#{@health[:error_count]}"
          puts "[#{@adapter.name}] ♥ #{msg}"
          @ck.log_event(type: 'heartbeat', content: msg, tags: {
            poll_count: @health[:poll_count].to_s, error_count: @health[:error_count].to_s
          })
        end

        sleep(@poll_interval)
      end
    end
  end
end
