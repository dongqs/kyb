# frozen_string_literal: true

module Kyb
  module Bot
    # 已读消息去重
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
  end
end
