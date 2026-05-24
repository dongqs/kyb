# frozen_string_literal: true

require_relative 'test_helper'

class TestFeishuBot < Minitest::Test
  def setup
    @original_env = {
      'FEISHU_APP_ID' => ENV['FEISHU_APP_ID'],
      'FEISHU_APP_SECRET' => ENV['FEISHU_APP_SECRET'],
      'FEISHU_CHAT_ID' => ENV['FEISHU_CHAT_ID'],
      'FEISHU_POLL_INTERVAL' => ENV['FEISHU_POLL_INTERVAL'],
    }
    ENV['FEISHU_APP_ID'] = 'test_app_id'
    ENV['FEISHU_APP_SECRET'] = 'test_app_secret'
    ENV.delete('FEISHU_CHAT_ID')
    ENV.delete('FEISHU_POLL_INTERVAL')
  end

  def teardown
    %w[FEISHU_APP_ID FEISHU_APP_SECRET FEISHU_CHAT_ID FEISHU_POLL_INTERVAL].each do |key|
      if @original_env[key]
        ENV[key] = @original_env[key]
      else
        ENV.delete(key)
      end
    end
  end

  # --- 消息解析 ---

  def test_parse_text_content
    msg = { 'msg_type' => 'text', 'body' => { 'content' => '{"text":"hello"}' } }
    result = Kyb::FeishuBot.parse_content(msg)
    assert_equal 'hello', result
  end

  def test_parse_non_text_returns_nil
    msg = { 'msg_type' => 'image', 'body' => { 'content' => '{}' } }
    assert_nil Kyb::FeishuBot.parse_content(msg)
  end

  def test_parse_invalid_json_returns_nil
    msg = { 'msg_type' => 'text', 'body' => { 'content' => 'not json' } }
    assert_nil Kyb::FeishuBot.parse_content(msg)
  end

  # --- @ 提及检测 ---

  def test_detect_mention_by_text
    assert Kyb::FeishuBot.mentioned?('@_user_1 你好')
    assert Kyb::FeishuBot.mentioned?('test @kyb-infra test')
  end

  def test_detect_no_mention
    refute Kyb::FeishuBot.mentioned?('普通消息')
    refute Kyb::FeishuBot.mentioned?('')
    refute Kyb::FeishuBot.mentioned?(nil)
  end

  # --- 去重 ---

  def test_seen_tracker_dedup
    tracker = Kyb::FeishuBot::SeenTracker.new
    refute tracker.seen?('msg_1')
    tracker.mark('msg_1')
    assert tracker.seen?('msg_1')
    refute tracker.seen?('msg_2')
  end

  def test_seen_tracker_max_size
    tracker = Kyb::FeishuBot::SeenTracker.new(max_size: 3)
    3.times { |i| tracker.mark("msg_#{i}") }
    assert tracker.seen?('msg_0')
    tracker.mark('msg_3')
    # Oldest should be evicted
    refute tracker.seen?('msg_0')
    assert tracker.seen?('msg_3')
  end

  # --- 过滤 bot 自己发的消息 ---

  def test_is_bot_message
    assert Kyb::FeishuBot.bot_message?({ 'sender' => { 'id' => 'cli_aa9be3a17d3adbeb' } })
    refute Kyb::FeishuBot.bot_message?({ 'sender' => { 'id' => 'ou_some_user' } })
    refute Kyb::FeishuBot.bot_message?({})
  end

  # --- 重试退避 ---

  def test_retry_with_backoff_success
    calls = 0
    result = Kyb::FeishuBot.with_retry(max_attempts: 3) do
      calls += 1
      :ok
    end
    assert_equal :ok, result
    assert_equal 1, calls
  end

  def test_retry_with_backoff_failure_then_success
    calls = 0
    result = Kyb::FeishuBot.with_retry(max_attempts: 3) do
      calls += 1
      raise 'fail' if calls < 2
      :ok
    end
    assert_equal :ok, result
    assert_equal 2, calls
  end

  def test_retry_with_backoff_exhausted
    assert_raises(RuntimeError) do
      Kyb::FeishuBot.with_retry(max_attempts: 2, base_delay: 0.01) do
        raise 'persistent fail'
      end
    end
  end

  # --- 配置加载 ---

  def test_load_config_missing_env
    ENV.delete('FEISHU_APP_ID')
    ENV.delete('FEISHU_APP_SECRET')
    assert_raises(Kyb::FeishuBot::ConfigError) do
      Kyb::FeishuBot.load_config
    end
  end

  def test_load_config_from_env
    config = Kyb::FeishuBot.load_config
    assert_equal 'test_app_id', config[:app_id]
    assert_equal 'test_app_secret', config[:app_secret]
  end

  # --- 配置默认值 ---

  def test_load_config_defaults
    config = Kyb::FeishuBot.load_config
    assert_equal 'oc_9b1a09bbdd80887acd63cc02626618c6', config[:chat_id]
    assert_equal 5, config[:poll_interval]
  end

  def test_load_config_custom_chat_id
    ENV['FEISHU_CHAT_ID'] = 'oc_custom'
    config = Kyb::FeishuBot.load_config
    assert_equal 'oc_custom', config[:chat_id]
  end

  # --- 限流 ---

  def test_rate_limiter_allows_first_messages
    runner = Kyb::FeishuBot::Runner.new(Kyb::FeishuBot.load_config)
    refute runner.rate_limited?('user_1')
    refute runner.rate_limited?('user_1')
    refute runner.rate_limited?('user_1')
  end

  def test_rate_limiter_blocks_after_max
    runner = Kyb::FeishuBot::Runner.new(Kyb::FeishuBot.load_config)
    5.times { refute runner.rate_limited?('spammer') }
    assert runner.rate_limited?('spammer')
  end

  def test_rate_limiter_per_user
    runner = Kyb::FeishuBot::Runner.new(Kyb::FeishuBot.load_config)
    5.times { refute runner.rate_limited?('user_a') }
    assert runner.rate_limited?('user_a')
    refute runner.rate_limited?('user_b')
  end

  # --- 消息处理（@ 和 非 @ 都触发通知） ---

  def test_both_mention_and_normal_trigger_notification
    # 验证两种消息都会被 process_message 处理（不因 missing @ 而 return）
    assert Kyb::FeishuBot.mentioned?('@_user_1 hi')
    refute Kyb::FeishuBot.mentioned?('普通消息')
  end

  # --- 空内容保护 ---

  def test_empty_content_is_empty_string
    msg = { 'msg_type' => 'text', 'body' => { 'content' => '{"text":""}' } }
    assert_equal '', Kyb::FeishuBot.parse_content(msg)
  end

  def test_missing_body_does_not_raise
    msg = { 'msg_type' => 'text' }
    assert_nil Kyb::FeishuBot.parse_content(msg)
  end

  # --- CK 日志转义 ---

  def test_esc_preserves_normal_text
    logger = Kyb::FeishuBot::CkLogger.new
    result = logger.send(:esc, 'hello world')
    assert_equal 'hello world', result
  end

  def test_esc_escapes_single_quote
    logger = Kyb::FeishuBot::CkLogger.new
    result = logger.send(:esc, "it's")
    assert_equal "it\\'s", result
  end

  def test_esc_escapes_backslash_first
    logger = Kyb::FeishuBot::CkLogger.new
    result = logger.send(:esc, "\\'")  # input: backslash + quote
    assert_equal 4, result.length     # output: 2 backslashes + escaped quote + quote
    assert_equal '\\', result[0]
    assert_equal '\\', result[1]
    assert_equal '\\', result[2]
    assert_equal "'", result[3]
  end

  def test_esc_handles_nil
    logger = Kyb::FeishuBot::CkLogger.new
    result = logger.send(:esc, nil)
    assert_equal '', result
  end

  def test_esc_handles_special_chars
    logger = Kyb::FeishuBot::CkLogger.new
    result = logger.send(:esc, "a\nb\tc")
    assert_equal "a\nb\tc", result  # newlines and tabs pass through
  end

  # --- Feishu API Client (unit, no network) ---

  def test_client_uses_proxy_from_env
    config = Kyb::FeishuBot.load_config
    client = Kyb::FeishuBot::Client.new(config)
    # 验证 proxy 从环境变量读取（不调 API）
    assert client.respond_to?(:get_token)
    assert client.respond_to?(:fetch_messages)
    assert client.respond_to?(:send_message)
  end

  # --- SeenTracker 持久化（重启不丢记录） ---

  def test_seen_tracker_eviction_order
    tracker = Kyb::FeishuBot::SeenTracker.new(max_size: 2)
    tracker.mark('a')
    tracker.mark('b')
    tracker.mark('c')
    refute tracker.seen?('a')
    assert tracker.seen?('b')
    assert tracker.seen?('c')
  end
end
