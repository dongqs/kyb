# frozen_string_literal: true

require_relative 'test_helper'

class ManageRmTest < Minitest::Test
  def setup
    # Stub Config to return a valid project with a real path
    Kyb::Config.define_singleton_method(:load) { nil }
    Kyb::Config.define_singleton_method(:project) { |_| { path: Dir.pwd } }

    # Stub Docker methods that rm calls (except remove_container, which
    # each test stubs locally to avoid define_singleton_method self issues)
    Kyb::Docker.define_singleton_method(:volume_rm) { |_| nil }
    Kyb::Docker.define_singleton_method(:clone_path) { |_, _| nil }

    # Stub Reporter
    Kyb::Reporter.define_singleton_method(:emit_container_rm) { |**| nil }
  end

  def teardown
    Kyb::Config.singleton_class.remove_method(:load) rescue nil
    Kyb::Config.singleton_class.remove_method(:project) rescue nil
    Kyb::Docker.singleton_class.remove_method(:remove_container) rescue nil
    Kyb::Docker.singleton_class.remove_method(:volume_rm) rescue nil
    Kyb::Docker.singleton_class.remove_method(:clone_path) rescue nil
    Kyb::Reporter.singleton_class.remove_method(:emit_container_rm) rescue nil
  end

  def test_rm_passes_container_name_to_remove_container
    # Bug: rm uses undefined `cname` instead of `c.name`
    # This test verifies that remove_container receives the correct container name.
    # Local variable capture avoids define_singleton_method's self == module issue.
    called_with = nil
    Kyb::Docker.define_singleton_method(:remove_container) { |name| called_with = name }

    Kyb::CLI.rm('test', 'branch', force: true)
    assert_equal 'kyb-test-branch', called_with
  end
end
