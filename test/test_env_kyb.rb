require_relative 'test_helper'

class EnvKybTest < Minitest::Test
  def repo_root
    File.expand_path('..', __dir__)
  end

  def test_env_kyb_file_exists_in_repo_root
    assert File.exist?(File.join(repo_root, '.env.kyb')),
           '.env.kyb should exist in project root'
  end

  def test_gitignore_contains_env
    gitignore = File.read(File.join(repo_root, '.gitignore'))
    lines = gitignore.split("\n")
    assert_includes lines, '.env', '.gitignore line item .env not found'
  end

  def test_gitignore_contains_env_kyb
    gitignore = File.read(File.join(repo_root, '.gitignore'))
    lines = gitignore.split("\n")
    assert_includes lines, '.env.kyb', '.gitignore line item .env.kyb not found'
  end
end
