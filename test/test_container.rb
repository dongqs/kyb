require_relative 'test_helper'

class ContainerTest < Minitest::Test
  # --- constants ---

  def test_base_image
    assert_equal 'kyb-base', Kyb::Container::BASE_IMAGE
  end

  def test_branch_prefix
    assert_equal 'kyb', Kyb::Container::BRANCH_PREFIX
  end

  def test_label
    assert_equal 'kyb=true', Kyb::Container::LABEL
  end

  def test_filter
    assert_equal 'name=kyb-', Kyb::Container.filter
  end

  # --- normal container ---

  def test_name
    c = Kyb::Container.new('niao', 'sandbox')
    assert_equal 'kyb-niao-sandbox', c.name
    assert_equal 'niao', c.project
    assert_equal 'sandbox', c.branch
  end

  def test_name_with_custom_branch
    c = Kyb::Container.new('niao', 'water')
    assert_equal 'kyb-niao-water', c.name
  end

  def test_to_s_equals_name
    c = Kyb::Container.new('niao', 'sandbox')
    assert_equal c.name, c.to_s
  end

  def test_hostname_equals_name
    c = Kyb::Container.new('niao', 'sandbox')
    assert_equal 'kyb-niao-sandbox', c.hostname
  end

  # --- git / worktree ---

  def test_git_branch
    c = Kyb::Container.new('niao', 'sandbox')
    assert_equal 'kyb/niao-sandbox', c.git_branch
  end

  def test_git_branch_with_custom_branch
    c = Kyb::Container.new('niao', 'water')
    assert_equal 'kyb/niao-water', c.git_branch
  end

  def test_worktree_path
    c = Kyb::Container.new('niao', 'sandbox')
    assert_equal File.expand_path('~/.local/share/kyb/worktrees/niao/kyb-niao-sandbox'), c.worktree_path
  end

  # --- volumes ---

  def test_claude_volume
    c = Kyb::Container.new('niao', 'sandbox')
    assert_equal 'kyb-niao-sandbox-claude', c.claude_volume
  end

  def test_home_volume
    c = Kyb::Container.new('niao', 'sandbox')
    assert_equal 'kyb-niao-sandbox-home', c.home_volume
  end

  def test_node_modules_volume
    c = Kyb::Container.new('niao', 'sandbox')
    assert_equal 'niao-node_modules', c.node_modules_volume
  end

  # --- image ---

  def test_project_image
    c = Kyb::Container.new('niao', 'sandbox')
    assert_equal 'kyb-niao', c.project_image
  end

end
