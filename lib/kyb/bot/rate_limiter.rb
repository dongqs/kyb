# frozen_string_literal: true

module Kyb
  module Bot
    # 限流：每个 sender 在时间窗口内最多 N 条
    class RateLimiter
      def initialize(window: 30, max: 5)
        @window = window
        @max = max
        @records = {}
      end

      def limited?(sender)
        now = Time.now.to_i
        @records[sender] ||= []
        @records[sender].reject! { |t| now - t > @window }
        return true if @records[sender].size >= @max
        @records[sender] << now
        false
      end
    end
  end
end
