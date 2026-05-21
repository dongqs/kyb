require_relative 'test_helper'

class EnterTest < Minitest::Test
  # --- build_default_prompt ---

  def test_build_prompt_base
    Kyb::Config.stub(:project, ->(*) { {} }) do
      prompt = Kyb::CLI.build_default_prompt(nil, 'test')
      assert_match(/先读一下项目文档/, prompt)
      refute_includes prompt, '过时'
    end
  end

  def test_build_prompt_with_stale_msg
    Kyb::Config.stub(:project, ->(*) { {} }) do
      prompt = Kyb::CLI.build_default_prompt('过时警告', 'test')
      assert_includes prompt, '过时警告'
    end
  end

  def test_build_prompt_with_extra
    Kyb::Config.stub(:project, ->(*) { { extra_prompt: '项目自定义' } }) do
      prompt = Kyb::CLI.build_default_prompt(nil, 'test')
      assert_includes prompt, '项目自定义'
    end
  end

  # --- build_send_keys ---

  def test_send_keys_bash
    cmd = Kyb::CLI.build_send_keys('bash', 'test', 'prompt')
    assert_equal 'cd ~/projects/test', cmd
  end

  def test_send_keys_claude
    cmd = Kyb::CLI.build_send_keys('claude', 'test', 'read doc')
    assert_match(/^cd ~\/projects\/test && mise trust && (kyb|\/home\/dev\/kyb\/bin\/kyb) session wrap claude --dangerously-skip-permissions 'read doc'$/, cmd)
  end

  def test_send_keys_kimi
    cmd = Kyb::CLI.build_send_keys('kimi', 'test', 'hello')
    assert_match(/-p 'hello'$/, cmd)
  end

  # --- docker_exec_args ---

  def test_docker_exec_args_default
    args = Kyb::CLI.docker_exec_args
    assert_includes args, 'docker'
    assert_includes args, 'exec'
    assert_includes args, '-it'
    assert_includes args, '-u'
    assert_includes args, 'dev'
  end

  def test_docker_exec_args_with_kimi_key
    ENV['KIMI_API_KEY'] = 'test-key-123'
    args = Kyb::CLI.docker_exec_args
    assert_includes args, 'KIMI_API_KEY=test-key-123'
  ensure
    ENV.delete('KIMI_API_KEY')
  end

  # --- stale_image_warning ---

  def test_stale_warning_nil_when_no_base_image
    Kyb::Docker.stub(:image_exists?, false) do
      assert_nil Kyb::CLI.stale_image_warning
    end
  end

  def test_stale_warning_nil_when_not_stale
    Kyb::Docker.stub(:image_exists?, true) do
      Kyb::Config.stub(:base_image_path, '/tmp') do
        Kyb::Docker.stub(:stale?, false) do
          assert_nil Kyb::CLI.stale_image_warning
        end
      end
    end
  end

  def test_build_prompt_includes_morning
    Kyb::Config.stub(:project, ->(*) { {} }) do
      prompt = Kyb::CLI.build_default_prompt(nil, 'test')
      assert_includes prompt, 'kyb morning'
    end
  end
end
