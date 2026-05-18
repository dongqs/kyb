require_relative 'test_helper'

class ConfigTest < Minitest::Test
  def setup
    Kyb::Config.instance_variable_set(:@config, nil)
  end

  def stub_config(data)
    # Use Object#stub so methods are properly restored after the block.
    # (define_singleton_method + remove_method permanently destroys module_functions.)
    Kyb::Config.stub(:load, data) do
    Kyb::Config.stub(:load_config, data) do
      yield
    end
    end
  end

  def test_project_ports_as_integers
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'ports' => [3000, 8080] } }) do
      proj = Kyb::Config.project('niao')
      assert_equal [3000, 8080], proj[:ports]
    end
  end

  def test_project_ports_empty_when_not_set
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } }) do
      proj = Kyb::Config.project('niao')
      assert_equal [], proj[:ports]
    end
  end

  def test_project_ports_single_value
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'ports' => 3000 } }) do
      proj = Kyb::Config.project('niao')
      assert_equal [3000], proj[:ports]
    end
  end

  def test_project_path_expanded
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } }) do
      proj = Kyb::Config.project('niao')
      assert_equal File.expand_path('~/niao'), proj[:path]
    end
  end

  # -- extra_prompt -------------------------------------------------------

  # -- claude_default_model -----------------------------------------------

  def test_claude_default_model_default
    stub_config('base' => {}) do
      assert_equal 'flash', Kyb::Config.claude_default_model
    end
  end

  def test_claude_default_model_custom
    stub_config('base' => { 'claude_default_model' => 'pro' }) do
      assert_equal 'pro', Kyb::Config.claude_default_model
    end
  end

  # -- kyb_repo ----------------------------------------------------------------

  def test_kyb_repo_nil_when_not_set
    stub_config('base' => {}) do
      assert_nil Kyb::Config.kyb_repo
    end
  end

  def test_kyb_repo_when_set
    stub_config('base' => { 'kyb_repo' => '~/github/kyb' }) do
      assert_equal File.expand_path('~/github/kyb'), Kyb::Config.kyb_repo
    end
  end

  # -- proxy --------------------------------------------------------------

  def test_proxy_default_nil
    stub_config('base' => {}) do
      assert_nil Kyb::Config.proxy
      assert_nil Kyb::Config.no_proxy
    end
  end

  def test_proxy_base_level
    stub_config('base' => { 'proxy' => 'socks5://host:2080', 'no_proxy' => '.internal' }) do
      assert_equal 'socks5://host:2080', Kyb::Config.proxy
      assert_equal '.internal', Kyb::Config.no_proxy
    end
  end

  def test_project_proxy_inherits_from_base
    stub_config('base' => { 'proxy' => 'socks5://host:2080', 'no_proxy' => '.internal' },
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } }) do
      proj = Kyb::Config.project('niao')
      assert_equal 'socks5://host:2080', proj[:proxy]
      assert_equal '.internal', proj[:no_proxy]
    end
  end

  def test_project_proxy_overrides_base
    stub_config('base' => { 'proxy' => 'socks5://host:2080', 'no_proxy' => '.internal' },
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'proxy' => 'http://local:3128', 'no_proxy' => '' } }) do
      proj = Kyb::Config.project('niao')
      assert_equal 'http://local:3128', proj[:proxy]
      assert_equal '', proj[:no_proxy]
    end
  end

  # -- cp_files ----------------------------------------------------------------

  def test_cp_files_nil_when_not_set
    stub_config('base' => {},
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } }) do
      proj = Kyb::Config.project('niao')
      assert_nil proj[:cp_files]
    end
  end

  def test_cp_files_from_project_only
    stub_config('base' => {},
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main',
                  'cp_files' => { '.env' => '.env.example' } } }) do
      proj = Kyb::Config.project('niao')
      assert_equal '.env.example', proj[:cp_files]['.env']
    end
  end

  def test_cp_files_from_base_only
    stub_config('base' => { 'cp_files' => { '.env.kyb' => '.env.kyb' } },
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } }) do
      proj = Kyb::Config.project('niao')
      assert_equal '.env.kyb', proj[:cp_files]['.env.kyb']
    end
  end

  def test_cp_files_merged_base_and_project
    stub_config('base' => { 'cp_files' => { '.env.kyb' => '.env.kyb' } },
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main',
                  'cp_files' => { '.env' => '.env.example' } } }) do
      proj = Kyb::Config.project('niao')
      assert_equal '.env.kyb', proj[:cp_files]['.env.kyb']
      assert_equal '.env.example', proj[:cp_files]['.env']
    end
  end

  def test_cp_files_project_overrides_base
    stub_config('base' => { 'cp_files' => { '.env.kyb' => '.env.kyb', '.env' => 'base.env' } },
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main',
                  'cp_files' => { '.env' => '.env.prod' } } }) do
      proj = Kyb::Config.project('niao')
      assert_equal '.env.kyb', proj[:cp_files]['.env.kyb']  # from base
      assert_equal '.env.prod', proj[:cp_files]['.env']     # overridden by project
    end
  end

  def test_cp_files_env_template_fills_when_missing
    stub_config('base' => {},
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main',
                  'env_template' => '.env.example' } }) do
      proj = Kyb::Config.project('niao')
      assert_equal '.env.example', proj[:cp_files]['.env']
    end
  end

  def test_cp_files_env_template_does_not_override_explicit
    # cp_files 和 env_template 同时定义 .env 时冲突报错
    stub_config('base' => {},
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main',
                  'cp_files' => { '.env' => '.env.local' }, 'env_template' => '.env.example' } }) do
      assert_raises SystemExit do
        Kyb::Config.project('niao')
      end
    end
  end

  def test_cp_files_env_template_does_not_override_base
    # base cp_files 定义了 .env + 项目有 env_template 时冲突报错
    stub_config('base' => { 'cp_files' => { '.env' => '.env.base' } },
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main',
                  'env_template' => '.env.example' } }) do
      assert_raises SystemExit do
        Kyb::Config.project('niao')
      end
    end
  end

  # -- sandbox_allowed_domains --------------------------------------------

  def test_sandbox_allowed_domains_defaults
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } }) do
      proj = Kyb::Config.project('niao')
      assert_includes proj[:sandbox_allowed_domains], '*.npmjs.org'
      assert_includes proj[:sandbox_allowed_domains], 'github.com'
      assert_includes proj[:sandbox_allowed_domains], 'localhost'
    end
  end

  def test_sandbox_allowed_domains_with_extra
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'sandbox_allowed_domains' => ['*.internal.corp.com'] } }) do
      proj = Kyb::Config.project('niao')
      assert_includes proj[:sandbox_allowed_domains], '*.npmjs.org'
      assert_includes proj[:sandbox_allowed_domains], '*.internal.corp.com'
    end
  end

  # -- timezone ------------------------------------------------------------

  def test_timezone_default
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } }) do
      proj = Kyb::Config.project('niao')
      assert_equal 'Asia/Shanghai', proj[:timezone]
    end
  end

  def test_timezone_custom
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'timezone' => 'America/New_York' } }) do
      proj = Kyb::Config.project('niao')
      assert_equal 'America/New_York', proj[:timezone]
    end
  end

  # -- extra_prompt -------------------------------------------------------

  def test_extra_prompt_nil_when_not_set
    stub_config('base' => {}, 'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } }) do
      proj = Kyb::Config.project('niao')
      assert_nil proj[:extra_prompt]
    end
  end

  def test_extra_prompt_from_base
    stub_config('base' => { 'extra_prompt' => '全局规则' },
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } }) do
      proj = Kyb::Config.project('niao')
      assert_equal '全局规则', proj[:extra_prompt]
    end
  end

  def test_extra_prompt_from_project
    stub_config('base' => {},
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'extra_prompt' => '项目规则' } }) do
      proj = Kyb::Config.project('niao')
      assert_equal '项目规则', proj[:extra_prompt]
    end
  end

  def test_extra_prompt_merged
    stub_config('base' => { 'extra_prompt' => '全局规则' },
                'projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'extra_prompt' => '项目规则' } }) do
      proj = Kyb::Config.project('niao')
      assert_equal '全局规则 项目规则', proj[:extra_prompt]
    end
  end

  # -- git_url ----------------------------------------------------------------

  def test_git_url_nil_when_not_set
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main' } }) do
      proj = Kyb::Config.project('niao')
      assert_nil proj[:git_url]
    end
  end

  def test_git_url_when_set
    stub_config('projects' => { 'niao' => { 'path' => '~/niao', 'base_branch' => 'main', 'git_url' => 'git@github.com:dongqs/niao.git' } }) do
      proj = Kyb::Config.project('niao')
      assert_equal 'git@github.com:dongqs/niao.git', proj[:git_url]
    end
  end
end
