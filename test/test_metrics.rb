# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

class MetricsTest < Minitest::Test
  # Helper: stub http_post so events are captured into the returned array
  def capture_events
    events = []
    handler = ->(_p, b) { events << JSON.parse(b) }
    Kyb::Reporter.stub(:http_post, handler) do
      Kyb::Config.stub(:reporting_enabled?, true) do
        yield events
      end
    end
  end

  # --- Reporter: new event types ------------------------------------------------

  def test_emit_container_create
    capture_events do |events|
      Kyb::Reporter.emit_container_create(project: 'niao', branch: 'water', mode: 'mount')
      refute_empty events
      assert_equal 'container_create', events.last['event']
      assert_equal 'niao', events.last['data']['project']
      assert_equal 'water', events.last['data']['branch']
      assert_equal 'mount', events.last['data']['mode']
    end
  end

  def test_emit_container_create_clone_mode
    capture_events do |events|
      Kyb::Reporter.emit_container_create(project: 'niao', branch: 'water', mode: 'clone')
      assert_equal 'clone', events.last['data']['mode']
    end
  end

  def test_emit_container_rm
    capture_events do |events|
      Kyb::Reporter.emit_container_rm(project: 'niao', had_did_children: true)
      refute_empty events
      assert_equal 'container_rm', events.last['event']
      assert_equal 'niao', events.last['data']['project']
      assert_equal true, events.last['data']['had_did_children']
    end
  end

  def test_emit_container_rm_no_children
    capture_events do |events|
      Kyb::Reporter.emit_container_rm(project: 'niao', had_did_children: false)
      assert_equal false, events.last['data']['had_did_children']
    end
  end

  def test_emit_session_start
    capture_events do |events|
      Kyb::Reporter.emit_session_start(project: 'niao', cli_type: 'claude')
      refute_empty events
      assert_equal 'session_start', events.last['event']
      assert_equal 'niao', events.last['data']['project']
      assert_equal 'claude', events.last['data']['cli_type']
    end
  end

  def test_emit_session_start_kimi
    capture_events do |events|
      Kyb::Reporter.emit_session_start(project: 'niao', cli_type: 'kimi')
      assert_equal 'kimi', events.last['data']['cli_type']
    end
  end

  def test_emit_exec
    capture_events do |events|
      Kyb::Reporter.emit_exec(project: 'niao', command: 'bundle exec rspec')
      refute_empty events
      assert_equal 'exec', events.last['event']
      assert_equal 'niao', events.last['data']['project']
      assert_equal 'bundle exec rspec', events.last['data']['command']
    end
  end

  def test_emit_dispatch
    capture_events do |events|
      Kyb::Reporter.emit_dispatch(task_type: 'code_review', target: 'feature/foo')
      refute_empty events
      assert_equal 'dispatch', events.last['event']
      assert_equal 'code_review', events.last['data']['task_type']
      assert_equal 'feature/foo', events.last['data']['target']
    end
  end

  def test_emit_complete
    capture_events do |events|
      Kyb::Reporter.emit_complete(task_type: 'code_review', duration: 120.5, outcome: 'success')
      refute_empty events
      assert_equal 'complete', events.last['event']
      assert_equal 'code_review', events.last['data']['task_type']
      assert_equal 120.5, events.last['data']['duration']
      assert_equal 'success', events.last['data']['outcome']
    end
  end

  def test_emit_heartbeat
    capture_events do |events|
      Kyb::Reporter.emit_heartbeat(container_count: 3, disk: '85%', mem: '2.1G/8G')
      refute_empty events
      assert_equal 'heartbeat', events.last['event']
      assert_equal 3, events.last['data']['container_count']
      assert_equal '85%', events.last['data']['disk']
      assert_equal '2.1G/8G', events.last['data']['mem']
    end
  end

  def test_disabled_skips_new_methods
    events = []
    handler = ->(_p, b) { events << JSON.parse(b) }
    Kyb::Reporter.stub(:http_post, handler) do
      Kyb::Config.stub(:reporting_enabled?, false) do
        Kyb::Reporter.emit_container_create(project: 'niao', branch: 'water', mode: 'mount')
      end
    end
    assert events.empty?
  end

  # --- CLI integration: event command -----------------------------------------

  def test_event_dispatch_command
    capture_events do |events|
      Kyb::CLI.dispatch(%w[event dispatch analysis feature/bar])
      refute_nil events.last
      assert_equal 'dispatch', events.last['event']
      assert_equal 'analysis', events.last['data']['task_type']
      assert_equal 'feature/bar', events.last['data']['target']
    end
  end

  def test_event_complete_command
    capture_events do |events|
      Kyb::CLI.dispatch(%w[event complete analysis 45.2 success])
      refute_nil events.last
      assert_equal 'complete', events.last['event']
      assert_equal 'analysis', events.last['data']['task_type']
      assert_equal 45.2, events.last['data']['duration']
      assert_equal 'success', events.last['data']['outcome']
    end
  end

  def test_event_heartbeat_command
    capture_events do |events|
      Kyb::Docker.stub(:ps_list, []) do
        Kyb::CLI.dispatch(%w[event heartbeat])
        refute_nil events.last
        assert_equal 'heartbeat', events.last['event']
      end
    end
  end

  def test_event_no_args_shows_help
    out, = capture_io { Kyb::CLI.dispatch(%w[event]) }
    assert_match(/kyb event/, out)
  end

  def test_event_dispatch_no_args_dies
    assert_raises(SystemExit) { capture_io { Kyb::CLI.dispatch(%w[event dispatch]) } }
  end

  def test_event_dispatch_one_arg_dies
    assert_raises(SystemExit) { capture_io { Kyb::CLI.dispatch(%w[event dispatch code_review]) } }
  end

  def test_event_complete_no_args_dies
    assert_raises(SystemExit) { capture_io { Kyb::CLI.dispatch(%w[event complete]) } }
  end

  def test_event_complete_three_args_dies
    assert_raises(SystemExit) { capture_io { Kyb::CLI.dispatch(%w[event complete analysis 45.2]) } }
  end

  # --- CLI integration: session wrap -------------------------------------------

  def test_session_wrap_emits_complete_event
    capture_events do |events|
      calls = []
      system_stub = ->(*a) { calls << a; true }
      Kyb::CLI.stub(:system, system_stub) do
        capture_io do
          Kyb::CLI.session_wrap('echo', ['hello'])
        end
      end

      refute_nil events.last
      assert_equal 'session_complete', events.last['event']
      assert_equal 'echo', events.last['data']['cli']
      assert events.last['data']['duration_seconds'] > 0
    end
  end
end
