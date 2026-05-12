require_relative 'test_helper'

class ParserTest < Minitest::Test
  PROJECTS = %w[myproject tts-server tts niao].freeze

  def setup
    Kyb::Config.define_singleton_method(:load) { nil }
    Kyb::Config.define_singleton_method(:project_names) { PROJECTS }
  end

  def teardown
    Kyb::Config.singleton_class.remove_method(:load)
    Kyb::Config.singleton_class.remove_method(:project_names)
  end

  # --- basic ---

  def test_exact_project_match_uses_sandbox_branch
    project, branch = Kyb::Parser.parse('myproject')
    assert_equal 'myproject', project
    assert_equal 'sandbox', branch
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
    assert_equal 'sandbox', branch
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
    assert_equal 'kyb-myproject-sandbox', Kyb::Parser.container('myproject')
    assert_equal 'kyb-myproject-test', Kyb::Parser.container('myproject-test')
    assert_equal 'kyb-tts-server-sandbox', Kyb::Parser.container('tts-server')
    assert_equal 'kyb-tts-server-test', Kyb::Parser.container('tts-server-test')
  end

  # --- unknown project ---

  def test_unknown_project_dies
    assert_raises(SystemExit) { Kyb::Parser.parse('nonexistent') }
  end
end
