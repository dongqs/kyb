# frozen_string_literal: true

require_relative 'test_helper'

class TestDingtalkBot < Minitest::Test
  def setup
    @original_token = ENV.delete('DINGTALK_BOT_TOKEN')
    ENV['DINGTALK_BOT_TOKEN'] = 'test-token-123'
  end

  def teardown
    if @original_token
      ENV['DINGTALK_BOT_TOKEN'] = @original_token
    else
      ENV.delete('DINGTALK_BOT_TOKEN')
    end
  end

  # --- 配置 ---

  def test_raises_without_token
    ENV.delete('DINGTALK_BOT_TOKEN')
    assert_raises(Kyb::DingtalkBot::ConfigError) do
      Kyb::DingtalkBot.webhook_url
    end
  end

  def test_webhook_url_built_from_token
    url = Kyb::DingtalkBot.webhook_url
    assert_match %r{^https://oapi\.dingtalk\.com/robot/send\?access_token=test-token-123$}, url
  end

  def test_raises_on_empty_token
    ENV['DINGTALK_BOT_TOKEN'] = ''
    assert_raises(Kyb::DingtalkBot::ConfigError) do
      Kyb::DingtalkBot.webhook_url
    end
  end

  # --- Text 消息 payload 构建 ---

  def test_build_text_payload_structure
    payload = Kyb::DingtalkBot.build_text_payload('hello', at_mobiles: [], at_all: false)
    assert_equal 'text', payload[:msgtype]
    assert_equal 'hello', payload[:text][:content]
    assert_equal [], payload[:at][:atMobiles]
    assert_equal false, payload[:at][:isAtAll]
  end

  def test_build_text_with_at_all
    payload = Kyb::DingtalkBot.build_text_payload('hi', at_mobiles: [], at_all: true)
    assert payload[:at][:isAtAll]
  end

  def test_build_text_with_at_mobiles
    payload = Kyb::DingtalkBot.build_text_payload('hi', at_mobiles: %w[13800138000], at_all: false)
    assert_equal %w[13800138000], payload[:at][:atMobiles]
  end

  # --- Markdown 消息 payload 构建 ---

  def test_build_markdown_payload
    payload = Kyb::DingtalkBot.build_markdown_payload('Title', '# Hello', at_mobiles: [], at_all: false)
    assert_equal 'markdown', payload[:msgtype]
    assert_equal 'Title', payload[:markdown][:title]
    assert_equal '# Hello', payload[:markdown][:text]
  end

  def test_build_markdown_with_at_mobiles
    payload = Kyb::DingtalkBot.build_markdown_payload('T', 'text', at_mobiles: %w[139], at_all: false)
    assert_equal %w[139], payload[:at][:atMobiles]
  end

  # --- 通知等级 ---

  def test_notify_levels_defined
    assert_equal '#00BB00', Kyb::DingtalkBot::LEVEL_COLORS['done']
    assert_equal '#FF8800', Kyb::DingtalkBot::LEVEL_COLORS['blocked']
    assert_equal '#FF0000', Kyb::DingtalkBot::LEVEL_COLORS['urgent']
  end

  def test_notify_returns_nil_when_no_token
    ENV.delete('DINGTALK_BOT_TOKEN')
    result = Kyb::DingtalkBot.notify('done', 'test')
    assert_nil result
  end

  # --- 方法存在性 ---

  def test_respond_to_send_text
    assert_respond_to Kyb::DingtalkBot, :send_text
  end

  def test_respond_to_send_markdown
    assert_respond_to Kyb::DingtalkBot, :send_markdown
  end

  def test_respond_to_notify
    assert_respond_to Kyb::DingtalkBot, :notify
  end

  def test_respond_to_build_text_payload
    assert_respond_to Kyb::DingtalkBot, :build_text_payload
  end

  def test_respond_to_build_markdown_payload
    assert_respond_to Kyb::DingtalkBot, :build_markdown_payload
  end
end
