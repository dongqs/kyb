require_relative 'test_helper'

class ConfigTest < Minitest::Test
  def setup
    Kyb::Config.instance_variable_set(:@config, nil)
  end

  def stub_config(data)
    Kyb::Config.define_singleton_method(:load) { @config = data }
    Kyb::Config.define_singleton_method(:load_config) { @config = data }
  end

  def teardown
    Kyb::Config.singleton_class.remove_method(:load) rescue nil
    Kyb::Config.singleton_class.remove_method(:load_config) rescue nil
  end

  def test_project_ports_as_integers
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'ports' => [3000, 8080] } })
    proj = Kyb::Config.project('niao')
    assert_equal [3000, 8080], proj[:ports]
  end

  def test_project_ports_empty_when_not_set
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } })
    proj = Kyb::Config.project('niao')
    assert_equal [], proj[:ports]
  end

  def test_project_ports_single_value
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'ports' => 3000 } })
    proj = Kyb::Config.project('niao')
    assert_equal [3000], proj[:ports]
  end

  def test_project_path_expanded
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } })
    proj = Kyb::Config.project('niao')
    assert_equal File.expand_path('~/niao'), proj[:path]
  end

  # -- extra_prompt -------------------------------------------------------

  # -- claude_default_model -----------------------------------------------

  def test_claude_default_model_default
    stub_config('base' => {})
    assert_equal 'flash', Kyb::Config.claude_default_model
  end

  def test_claude_default_model_custom
    stub_config('base' => { 'claude_default_model' => 'pro' })
    assert_equal 'pro', Kyb::Config.claude_default_model
  end

  # -- proxy --------------------------------------------------------------

  def test_proxy_default_nil
    stub_config('base' => {})
    assert_nil Kyb::Config.proxy
    assert_nil Kyb::Config.no_proxy
  end

  def test_proxy_base_level
    stub_config('base' => { 'proxy' => 'socks5://host:2080', 'no_proxy' => '.internal' })
    assert_equal 'socks5://host:2080', Kyb::Config.proxy
    assert_equal '.internal', Kyb::Config.no_proxy
  end

  def test_project_proxy_inherits_from_base
    stub_config('base' => { 'proxy' => 'socks5://host:2080', 'no_proxy' => '.internal' },
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } })
    proj = Kyb::Config.project('niao')
    assert_equal 'socks5://host:2080', proj[:proxy]
    assert_equal '.internal', proj[:no_proxy]
  end

  def test_project_proxy_overrides_base
    stub_config('base' => { 'proxy' => 'socks5://host:2080', 'no_proxy' => '.internal' },
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'proxy' => 'http://local:3128', 'no_proxy' => '' } })
    proj = Kyb::Config.project('niao')
    assert_equal 'http://local:3128', proj[:proxy]
    assert_equal '', proj[:no_proxy]
  end

  # -- sandbox_allowed_domains --------------------------------------------

  def test_sandbox_allowed_domains_defaults
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } })
    proj = Kyb::Config.project('niao')
    assert_includes proj[:sandbox_allowed_domains], '*.npmjs.org'
    assert_includes proj[:sandbox_allowed_domains], 'github.com'
    assert_includes proj[:sandbox_allowed_domains], 'localhost'
  end

  def test_sandbox_allowed_domains_with_extra
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'sandbox_allowed_domains' => ['*.internal.corp.com'] } })
    proj = Kyb::Config.project('niao')
    assert_includes proj[:sandbox_allowed_domains], '*.npmjs.org'
    assert_includes proj[:sandbox_allowed_domains], '*.internal.corp.com'
  end

  # -- timezone ------------------------------------------------------------

  def test_timezone_default
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } })
    proj = Kyb::Config.project('niao')
    assert_equal 'Asia/Shanghai', proj[:timezone]
  end

  def test_timezone_custom
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'timezone' => 'America/New_York' } })
    proj = Kyb::Config.project('niao')
    assert_equal 'America/New_York', proj[:timezone]
  end

  # -- extra_prompt -------------------------------------------------------

  def test_extra_prompt_nil_when_not_set
    stub_config('base' => {}, 'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } })
    proj = Kyb::Config.project('niao')
    assert_nil proj[:extra_prompt]
  end

  def test_extra_prompt_from_base
    stub_config('base' => { 'extra_prompt' => '全局规则' },
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } })
    proj = Kyb::Config.project('niao')
    assert_equal '全局规则', proj[:extra_prompt]
  end

  def test_extra_prompt_from_project
    stub_config('base' => {},
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'extra_prompt' => '项目规则' } })
    proj = Kyb::Config.project('niao')
    assert_equal '项目规则', proj[:extra_prompt]
  end

  def test_extra_prompt_merged
    stub_config('base' => { 'extra_prompt' => '全局规则' },
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'extra_prompt' => '项目规则' } })
    proj = Kyb::Config.project('niao')
    assert_equal '全局规则 项目规则', proj[:extra_prompt]
  end
end
