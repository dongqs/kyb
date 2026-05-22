# frozen_string_literal: true

require_relative 'test_helper'

class ReporterTest < Minitest::Test
  def setup
    @_orig_reporter = {}
    %i[http_post reporting_enabled?].each { |m| @_orig_reporter[m] = Kyb::Reporter.method(m) rescue nil }
    @_orig_config_reporting = Kyb::Config.method(:reporting_enabled?) rescue nil
  end

  def teardown
    %i[http_post reporting_enabled?].each do |m|
      next unless @_orig_reporter[m]
      Kyb::Reporter.define_singleton_method(m, @_orig_reporter[m])
    end
    if @_orig_config_reporting
      Kyb::Config.define_singleton_method(:reporting_enabled?, @_orig_config_reporting)
    end
  end

  def test_default_enabled
    assert Kyb::Reporter.enabled?
  end

  def test_disabled_via_config
    Kyb::Config.define_singleton_method(:reporting_enabled?) { false }
    refute Kyb::Reporter.enabled?
  end

  def test_emit_sends_post
    posted = nil
    Kyb::Reporter.define_singleton_method(:http_post) { |p, b| posted = { p: p, b: b } }
    Kyb::Reporter.emit('test_event', { foo: 'bar' })
    refute_nil posted
    assert_includes posted[:b], 'test_event'
  end

  def test_fire_and_forget
    Kyb::Reporter.define_singleton_method(:http_post) { |_, _| raise RuntimeError, 'boom' }
    _, err = capture_io { Kyb::Reporter.emit('test_event', {}) }
    assert_match(/boom/, err)
  end

  def test_disabled_skips
    posted = false
    Kyb::Reporter.define_singleton_method(:http_post) { |_, _| posted = true }
    Kyb::Config.define_singleton_method(:reporting_enabled?) { false }
    Kyb::Reporter.emit('test_event', {})
    refute posted
  end

  def test_emit_build_duration
    Kyb::Config.define_singleton_method(:reporting_enabled?) { true }
    posted = nil
    Kyb::Reporter.define_singleton_method(:http_post) { |p, b| posted = { p: p, b: b } }
    Kyb::Reporter.emit_build_duration(duration: 1.5, success: true)
    refute_nil posted
    assert_includes posted[:b], 'kyb_build_duration'
  end

  def test_emit_create_event
    Kyb::Config.define_singleton_method(:reporting_enabled?) { true }
    posted = []
    Kyb::Reporter.define_singleton_method(:http_post) { |p, b| posted << { p: p, b: b } }
    Kyb::Reporter.emit_create_event(container: 'test-c', project: 'test')
    refute_empty posted
    assert_includes posted.first[:b], 'kyb_create_count'
  end

  def test_emit_rm_event
    Kyb::Config.define_singleton_method(:reporting_enabled?) { true }
    posted = []
    Kyb::Reporter.define_singleton_method(:http_post) { |p, b| posted << { p: p, b: b } }
    Kyb::Reporter.emit_rm_event(container: 'test-c', duration: 100)
    refute_empty posted
    assert_includes posted.first[:b], 'kyb_rm_count'
  end

  def test_emit_container_count
    Kyb::Config.define_singleton_method(:reporting_enabled?) { true }
    posted = nil
    Kyb::Reporter.define_singleton_method(:http_post) { |p, b| posted = { p: p, b: b } }
    Kyb::Reporter.emit_container_count(count: 3)
    refute_nil posted
    assert_includes posted[:b], 'kyb_container_count'
  end

  def test_reporting_enabled_default
    assert Kyb::Config.reporting_enabled?
  end

  def test_reporting_disabled_explicit
    orig = Kyb::Config.method(:load_config)
    Kyb::Config.define_singleton_method(:load_config) { { 'reporting' => { 'enabled' => false } } }
    Kyb::Config.instance_variable_set(:@config, nil) rescue nil
    refute Kyb::Config.reporting_enabled?
  ensure
    Kyb::Config.singleton_class.remove_method(:load_config)
    Kyb::Config.define_singleton_method(:load_config, orig) if orig
    Kyb::Config.instance_variable_set(:@config, nil) rescue nil
  end
end
