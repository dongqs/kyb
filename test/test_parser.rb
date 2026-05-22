require_relative 'test_helper'

class ParserTest < Minitest::Test
  PROJECTS = %w[myproject tts-server tts niao].freeze

  def setup
    @_orig_load = Kyb::Config.method(:load) rescue nil
    @_orig_names = Kyb::Config.method(:project_names) rescue nil
    Kyb::Config.define_singleton_method(:load) { nil }
    Kyb::Config.define_singleton_method(:project_names) { PROJECTS }
  end

  def teardown
    Kyb::Config.define_singleton_method(:load, @_orig_load) if @_orig_load
    Kyb::Config.define_singleton_method(:project_names, @_orig_names) if @_orig_names
  end

  # --- basic ---

  def test_exact_project_match_uses_default_branch
    project, branch = Kyb::Parser.parse('myproject')
    assert_equal 'myproject', project
    assert_equal 'kyb', branch
  end

  def test_project_with_branch
    project, branch = Kyb::Parser.parse('myproject-test')
    assert_equal 'myproject', project
    assert_equal 'test', branch
  end

  def test_branch_contains_dashes
    project, branch = Kyb::Parser.parse('myproject-feature-add-login')
    assert_equal 'myproject', project
    assert_equal 'feature-add-login', branch
  end

  # --- multi-dash project name ---

  def test_multi_dash_project_exact_match
    project, branch = Kyb::Parser.parse('tts-server')
    assert_equal 'tts-server', project
    assert_equal 'kyb', branch
  end

  def test_multi_dash_project_with_branch
    project, branch = Kyb::Parser.parse('tts-server-test')
    assert_equal 'tts-server', project
    assert_equal 'test', branch
  end

  # --- ambiguity (longest wins) ---

  def test_ambiguity_picks_longest
    project, branch = Kyb::Parser.parse('tts-server-test')
    assert_equal 'tts-server', project
    assert_equal 'test', branch
  end

  # --- container name ---

  def test_container_name
    assert_equal 'kyb-myproject-kyb', Kyb::Parser.container('myproject')
    assert_equal 'kyb-myproject-test', Kyb::Parser.container('myproject-test')
    assert_equal 'kyb-tts-server-kyb', Kyb::Parser.container('tts-server')
    assert_equal 'kyb-tts-server-test', Kyb::Parser.container('tts-server-test')
  end

  # --- branch validation ---

  def test_parse_rejects_slash
    assert_raises(SystemExit) { Kyb::Parser.parse('myproject-feature/x') }
  end

  def test_parse_rejects_at_sign
    assert_raises(SystemExit) { Kyb::Parser.parse('myproject-branch@foo') }
  end

  def test_parse_rejects_leading_dot
    assert_raises(SystemExit) { Kyb::Parser.parse('myproject-.hidden') }
  end

  def test_parse_rejects_empty
    assert_raises(SystemExit) { Kyb::Parser.parse('myproject-') }
  end

  def test_parse_accepts_normal_branch
    project, branch = Kyb::Parser.parse('myproject-feature-add-login')
    assert_equal 'myproject', project
    assert_equal 'feature-add-login', branch
  end

  # --- unknown project ---

  def test_unknown_project_dies
    assert_raises(SystemExit) { Kyb::Parser.parse('nonexistent') }
  end
end
