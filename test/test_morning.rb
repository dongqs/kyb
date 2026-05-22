require_relative 'test_helper'

class MorningTest < Minitest::Test
  def setup
    @_orig_morning = {}
    %i[
      morning_hostname morning_project morning_branch morning_user
      morning_git_status_text morning_docker_running morning_docker_images_size
      morning_disk_pct morning_pg_ready? morning_ck_table_info
      morning_proxy_url morning_proxy_check morning_recent_events morning_batch_tasks
    ].each { |m|
      @_orig_morning[m] = Kyb::CLI.method(m) rescue nil }
    require_relative '../lib/kyb/cli/morning'
    Kyb::CLI.define_singleton_method(:morning_hostname) { 'kyb-test-box' }
    Kyb::CLI.define_singleton_method(:morning_project) { 'test' }
    Kyb::CLI.define_singleton_method(:morning_branch) { 'dev' }
    Kyb::CLI.define_singleton_method(:morning_user) { 'tester' }
    Kyb::CLI.define_singleton_method(:morning_git_status_text) { 'clean' }
    Kyb::CLI.define_singleton_method(:morning_docker_running) { 3 }
    Kyb::CLI.define_singleton_method(:morning_docker_images_size) { '12G' }
    Kyb::CLI.define_singleton_method(:morning_disk_pct) { '42%' }
    Kyb::CLI.define_singleton_method(:morning_pg_ready?) { true }
    Kyb::CLI.define_singleton_method(:morning_ck_table_info) { 'kyb.agent_events table ready (5 rows)' }
    Kyb::CLI.define_singleton_method(:morning_proxy_url) { 'socks5://host.orb.internal:2080' }
    Kyb::CLI.define_singleton_method(:morning_proxy_check) { |_| true }
    Kyb::CLI.define_singleton_method(:morning_recent_events) { ['  [09:00] result: Fixed Nexus 403'] }
    Kyb::CLI.define_singleton_method(:morning_batch_tasks) { ['[Wave 1] treasure: running'] }
  end

  def teardown
    %i[
      morning_hostname morning_project morning_branch morning_user
      morning_git_status_text morning_docker_running morning_docker_images_size
      morning_disk_pct morning_pg_ready? morning_ck_table_info
      morning_proxy_url morning_proxy_check morning_recent_events morning_batch_tasks
    ].each { |m|
      Kyb::CLI.define_singleton_method(m, @_orig_morning[m]) if @_orig_morning[m]
    }
  end

  def test_header
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/Good Morning/, out)
    assert_match(/／人◕ ‿‿ ◕人＼/, out)
  end

  def test_whoami_section
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/── Who am I ──/, out)
    assert_match(/Container: kyb-test-box \(test\)/, out)
    assert_match(/Branch: dev/, out)
    assert_match(/User: tester/, out)
  end

  def test_whoami_no_project
    Kyb::CLI.define_singleton_method(:morning_project) { nil }
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/Container: kyb-test-box$/, out)
  end

  def test_whereami_section
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/── Where am I ──/, out)
    assert_match(/Git: clean/, out)
    assert_match(/Docker: 3 container/, out)
    assert_match(/12G images/, out)
    assert_match(/42% disk/, out)
    assert_match(/PG: accepting connections/, out)
    assert_match(/CK: kyb.agent_events table ready/, out)
    assert_match(%r{Proxy: socks5://host.orb.internal:2080 OK}, out)
  end

  def test_git_changes
    Kyb::CLI.define_singleton_method(:morning_git_status_text) { '3 file(s) modified, 2 commit(s) unpushed' }
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/3 file\(s\) modified/, out)
    assert_match(/2 commit\(s\) unpushed/, out)
  end

  def test_pg_not_available
    Kyb::CLI.define_singleton_method(:morning_pg_ready?) { false }
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/PG: not available/, out)
  end

  def test_ck_not_available
    Kyb::CLI.define_singleton_method(:morning_ck_table_info) { 'not available (CK not reachable)' }
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/CK: not available/, out)
  end

  def test_proxy_not_reachable
    Kyb::CLI.define_singleton_method(:morning_proxy_check) { |_| false }
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/not reachable/, out)
  end

  def test_proxy_not_configured
    Kyb::CLI.define_singleton_method(:morning_proxy_url) { nil }
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/not configured/, out)
  end

  def test_yesterday_section
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/Yesterday's work/, out)
    assert_match(/Fixed Nexus 403/, out)
  end

  def test_no_recent_events
    Kyb::CLI.define_singleton_method(:morning_recent_events) { [] }
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/no recent events/, out)
  end

  def test_ck_unavailable_yesterday
    Kyb::CLI.define_singleton_method(:morning_recent_events) { nil }
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/CK unavailable/, out)
  end

  def test_todo_section
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/── What to do ──/, out)
    assert_match(/Onboarding batches active/, out)
    assert_match(/treasure: running/, out)
  end

  def test_no_batch_tasks
    Kyb::CLI.define_singleton_method(:morning_batch_tasks) { nil }
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/default/, out)
    assert_match(/Review code/, out)
  end

  def test_commands_section
    out, _ = capture_io { Kyb::CLI.morning }
    assert_match(/── Quick commands ──/, out)
    assert_match(/kyb ps/, out)
    assert_match(/kyb doctor/, out)
    assert_match(/kyb prod ck/, out)
    assert_match(/kyb enter/, out)
  end

  def test_morning_dispatch
    Kyb::CLI.instance_variable_set(:@__captured, nil)
    orig = Kyb::CLI.method(:morning) rescue nil
    Kyb::CLI.define_singleton_method(:morning) { |*| Kyb::CLI.instance_variable_set(:@__captured, [:morning]) }
    Kyb::CLI.dispatch(%w[morning])
    assert_equal [:morning], Kyb::CLI.instance_variable_get(:@__captured)
  ensure
    Kyb::CLI.define_singleton_method(:morning, orig) if orig
  end
end
