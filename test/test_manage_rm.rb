# frozen_string_literal: true

require_relative 'test_helper'

class ManageRmTest < Minitest::Test
  def setup
    # Save originals so teardown can restore them
    @_orig_config = {}
    %i[load project].each { |m| @_orig_config[m] = Kyb::Config.method(m) rescue nil }

    # Stub Config to return a valid project with a real path
    Kyb::Config.define_singleton_method(:load) { nil }
    Kyb::Config.define_singleton_method(:project) { |_| { path: Dir.pwd } }

    # Save and stub Docker methods that rm calls
    @_orig_docker = {}
    %i[volume_rm clone_path].each { |m| @_orig_docker[m] = Kyb::Docker.method(m) rescue nil }
    Kyb::Docker.define_singleton_method(:volume_rm) { |_| nil }
    Kyb::Docker.define_singleton_method(:clone_path) { |_, _| nil }

    # Save and stub Reporter
    @_orig_reporter = {}
    @_orig_reporter[:emit_container_rm] = Kyb::Reporter.method(:emit_container_rm) rescue nil
    Kyb::Reporter.define_singleton_method(:emit_container_rm) { |**| nil }
  end

  def teardown
    @_orig_config.each { |m, orig| Kyb::Config.define_singleton_method(m, orig) if orig }
    # Restore Docker methods (IMPORTANT: use define_singleton_method, not remove_method,
    # which permanently nukes module_function methods from the singleton class)
    @_orig_docker.each { |m, orig| Kyb::Docker.define_singleton_method(m, orig) if orig }
    @_orig_reporter.each { |m, orig| Kyb::Reporter.define_singleton_method(m, orig) if orig }
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
