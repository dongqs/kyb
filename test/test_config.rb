require_relative 'test_helper'

class ConfigTest < Minitest::Test
  def setup
    Kyb::Config.instance_variable_set(:@config, nil)
  end

  def stub_config(data)
    Kyb::Config.define_singleton_method(:load) { @config = data }
  end

  def teardown
    Kyb::Config.singleton_class.remove_method(:load) rescue nil
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
