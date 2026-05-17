require_relative 'test_helper'
require 'net/http'
require 'json'

class TTSServerTest < Minitest::Test
  BASE = 'http://localhost:10666'

  def setup
    skip 'TTS server not running' unless tts_running?
  end

  def tts_running?
    Net::HTTP.get_response(URI("#{BASE}/health"))
    true
  rescue Errno::ECONNREFUSED, Errno::ESOCKETTIMEOUT
    false
  end

  def notify(level:, text:)
    uri = URI("#{BASE}/notify")
    Net::HTTP.post(uri, { level: level, text: text }.to_json,
                   'Content-Type' => 'application/json')
  end

  def test_notify_done
    resp = notify(level: 'done', text: 'test done')
    assert_equal '200', resp.code
    data = JSON.parse(resp.body)
    assert_equal 'ok', data['status']
    assert_equal 'done', data['level']
    assert_nil data['retry_hint']
  end

  def test_notify_blocked
    resp = notify(level: 'blocked', text: 'test blocked')
    assert_equal '200', resp.code
    data = JSON.parse(resp.body)
    assert_equal 'blocked', data['level']
    assert data['retry_hint']
    assert_includes data['retry_hint'], '60s'
  end

  def test_notify_urgent
    resp = notify(level: 'urgent', text: 'test urgent')
    assert_equal '200', resp.code
    data = JSON.parse(resp.body)
    assert_equal 'urgent', data['level']
    assert data['retry_hint']
  end

  def test_notify_invalid_level
    resp = notify(level: 'invalid', text: 'test')
    assert_equal '400', resp.code
    data = JSON.parse(resp.body)
    assert_equal 'error', data['status']
  end

  def test_notify_missing_text_defaults
    uri = URI("#{BASE}/notify")
    resp = Net::HTTP.post(uri, { level: 'done' }.to_json,
                          'Content-Type' => 'application/json')
    assert_equal '200', resp.code
  end
end
