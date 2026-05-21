# frozen_string_literal: true

require_relative 'test_helper'

class WorldviewTest < Minitest::Test
  WORLDVIEW_DIR = File.expand_path('../lib/kyb/worldviews', __dir__)
  EXPECTED = {
    'system-cybernetics' => /系统论|控制论|反馈环|涌现/,
    'scientific-empiricism' => /假设|实验|数据|结论/,
    'marxist-dialectics' => /矛盾|实践|主要矛盾/,
    'first-principles' => /第一性原理|拆到不可分|质疑/,
    'stoic-pragmatism' => /可控|不可控|最小可行|渐进/,
  }.freeze
  def setup
    @_orig_config = {}
    %i[load project].each { |m| @_orig_config[m] = Kyb::Config.method(m) rescue nil }
    Kyb::Config.define_singleton_method(:load) { nil }
    Kyb::Config.define_singleton_method(:project) { |_| {} }
  end
  def teardown
    @_orig_config.each { |m, orig| Kyb::Config.define_singleton_method(m, orig) if orig }
  end
  def test_worldview_files_exist
    EXPECTED.each_key { |n| assert File.exist?(File.join(WORLDVIEW_DIR, "#{n}.md")) }
  end
  def test_worldview_files_have_minimum_length
    EXPECTED.each_key { |n| assert File.read(File.join(WORLDVIEW_DIR, "#{n}.md")).split(/\n\s*\n/).size >= 3 }
  end
  def test_worldview_files_have_chinese_content
    EXPECTED.each { |n, re| assert_match(re, File.read(File.join(WORLDVIEW_DIR, "#{n}.md"))) }
  end
  def test_worldview_list_returns_all
    assert_equal EXPECTED.keys.sort, Kyb::Worldview.list.map { |w| w[:name] }.sort
  end
  def test_worldview_list_has_descriptions
    Kyb::Worldview.list.each { |w| refute_empty w[:description] }
  end
  def test_worldview_show_returns_content
    EXPECTED.each { |n, re| assert_match(re, Kyb::Worldview.show(n)) }
  end
  def test_worldview_show_unknown_returns_nil
    assert_nil Kyb::Worldview.show('nonexistent')
  end
  def test_worldview_random_returns_valid
    10.times { assert EXPECTED.key?(Kyb::Worldview.random[:name]) }
  end
  def test_worldview_load_worldview_returns_content
    EXPECTED.each_key { |n| assert Kyb::Worldview.load_worldview(n).length > 100 }
  end
  def test_worldview_injects_into_prompt
    Kyb::Worldview.stub(:show, ->(_) { '## SYNC' }) { assert_match(/SYNC/, Kyb::CLI.inject_worldview('base', 'test')) }
  end
  def test_worldview_nil_returns_unchanged
    assert_equal 'original', Kyb::CLI.inject_worldview('original', nil)
  end
  def test_inject_worldview_appends_real_content
    c = Kyb::Worldview.show('system-cybernetics')
    p = Kyb::CLI.inject_worldview('base', 'system-cybernetics')
    assert_includes p, c.strip
    assert_includes p, '## 世界观'
  end
  def test_resolve_cli_arg_overrides_stored
    c = 'kyb-niao-test-cli'
    begin
      Kyb::Worldview.assign(c, 'stoic-pragmatism')
      assert_equal 'system-cybernetics', Kyb::CLI.resolve_worldview('system-cybernetics', c)
    ensure
      FileUtils.rm_f(Kyb::Worldview.assignment_path(c))
    end
  end
  def test_resolve_falls_back_to_stored
    c = "kyb-niao-#{Time.now.to_i}-#{rand(9999)}"
    begin
      Kyb::Worldview.assign(c, 'marxist-dialectics')
      assert_equal 'marxist-dialectics', Kyb::CLI.resolve_worldview(nil, c)
    ensure
      FileUtils.rm_f(Kyb::Worldview.assignment_path(c))
    end
  end
  def test_resolve_nil_when_not_set
    assert_nil Kyb::CLI.resolve_worldview(nil, "kyb-test-#{Time.now.to_i}")
  end
  def test_list_dispatch
    out, _ = capture_io { Kyb::CLI.dispatch(%w[worldview list]) }
    EXPECTED.each_key { |n| assert_match(/#{n}/, out) }
  end
  def test_show_dispatch
    out, _ = capture_io { Kyb::CLI.dispatch(%w[worldview show system-cybernetics]) }
    assert_match(/系统论|控制论/, out)
  end
  def test_show_unknown_dies
    assert_raises(SystemExit) { capture_io { Kyb::CLI.dispatch(%w[worldview show nonexistent]) } }
  end
  def test_diversity_samples_unique
    n = Kyb::Worldview.sample_without_replacement(3)
    assert_equal 3, n.size
    assert_equal n.uniq.size, n.size
  end
  def test_diversity_capped
    assert_equal EXPECTED.keys.size, Kyb::Worldview.sample_without_replacement(10).size
  end
  def test_diversity_zero
    assert_empty Kyb::Worldview.sample_without_replacement(0)
    assert_empty Kyb::Worldview.sample_without_replacement(-1)
  end
  def test_assignment_rw
    c = 'kyb-niao-test-rw'
    begin
      Kyb::Worldview.assign(c, 'stoic-pragmatism')
      assert_equal 'stoic-pragmatism', Kyb::Worldview.assigned(c)
      Kyb::Worldview.assign(c, nil)
      assert_nil Kyb::Worldview.assigned(c)
    ensure
      FileUtils.rm_f(Kyb::Worldview.assignment_path(c))
    end
  end
  def test_assignment_for_unassigned
    assert_nil Kyb::Worldview.assigned("kyb-test-#{Time.now.to_i}")
  end
end
