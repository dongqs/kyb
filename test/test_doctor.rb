# frozen_string_literal: true
require_relative 'test_helper'

class DoctorTest < Minitest::Test
  DOCTOR_METHODS = %i[doctor_ps_raw doctor_container_tmux_alive? doctor_volume_names
                      doctor_container_volumes].freeze

  def setup
    require_relative '../lib/kyb/cli/doctor'
    @_orig_doctor = {}
    DOCTOR_METHODS.each { |m| @_orig_doctor[m] = Kyb::CLI.method(m) rescue nil }
    Kyb::CLI.define_singleton_method(:doctor_ps_raw) {
      [%w[kyb-niao-dev Up\ 10\ minutes], %w[kyb-rest-version Up\ 4\ hours],
       %w[kyb-rest-debug Up\ 5\ hours], %w[kyb-tts-test Exited\ 2\ hours\ ago]] }
    Kyb::CLI.define_singleton_method(:doctor_container_tmux_alive?) { |c| %w[kyb-niao-dev kyb-rest-version].include?(c) }
    Kyb::CLI.define_singleton_method(:doctor_volume_names) {
      %w[kyb-niao-dev-claude kyb-rest-version-claude kyb-rest-debug-claude
         kyb-tts-test-claude kyb-gradle-cache kyb-maven-cache kyb-orphan-volume] }
    Kyb::CLI.define_singleton_method(:doctor_container_volumes) { |c|
      h = { 'kyb-niao-dev' => %w[kyb-niao-dev-claude],
            'kyb-rest-version' => %w[kyb-rest-version-claude],
            'kyb-rest-debug' => %w[kyb-rest-debug-claude],
            'kyb-tts-test' => %w[kyb-tts-test-claude] }; h[c] || [] }
  end
  def teardown
    @_orig_doctor&.each { |m, orig| Kyb::CLI.define_singleton_method(m, orig) if orig }
  end
  def test_scan_containers
    c = Kyb::CLI.doctor_scan_containers
    assert c.find { |x| x[:name] == 'kyb-niao-dev' }[:alive]
    refute c.find { |x| x[:name] == 'kyb-rest-debug' }[:alive]
  end
  def test_volume_orphan
    v = Kyb::CLI.doctor_scan_volumes(Kyb::CLI.doctor_scan_containers)
    assert v.find { |x| x[:name] == 'kyb-orphan-volume' }[:orphan]
  end
  def test_volume_cache
    v = Kyb::CLI.doctor_scan_volumes(Kyb::CLI.doctor_scan_containers)
    g = v.find { |x| x[:name] == 'kyb-gradle-cache' }
    assert g[:cache]; refute g[:orphan]
  end
  def test_volume_alive_in_use
    v = Kyb::CLI.doctor_scan_volumes(Kyb::CLI.doctor_scan_containers)
    x = v.find { |vol| vol[:name] == 'kyb-niao-dev-claude' }
    assert x[:in_use]; refute x[:orphan]
  end
  def test_volume_stale_orphan
    v = Kyb::CLI.doctor_scan_volumes(Kyb::CLI.doctor_scan_containers)
    assert v.find { |vol| vol[:name] == 'kyb-rest-debug-claude' }[:orphan]
  end
  def test_report
    out, = capture_io { Kyb::CLI.doctor_print_report(
      Kyb::CLI.doctor_scan_containers,
      Kyb::CLI.doctor_scan_volumes(Kyb::CLI.doctor_scan_containers)) }
    assert_match(/容器/, out); assert_match(/Summary/, out)
  end
  def test_cleanup
    removed = []
    Kyb::CLI.define_singleton_method(:doctor_stop_and_rm) { |c| removed << c }
    Kyb::CLI.define_singleton_method(:doctor_volume_rm) { |_| }
    capture_io { Kyb::CLI.doctor_cleanup(
      Kyb::CLI.doctor_scan_containers,
      Kyb::CLI.doctor_scan_volumes(Kyb::CLI.doctor_scan_containers)) }
    assert_includes removed, 'kyb-rest-debug'
    refute_includes removed, 'kyb-niao-dev'
  end
  def test_cleanup_orphans
    removed = []
    Kyb::CLI.define_singleton_method(:doctor_stop_and_rm) { |_| }
    Kyb::CLI.define_singleton_method(:doctor_volume_rm) { |v| removed << v }
    capture_io { Kyb::CLI.doctor_cleanup(
      Kyb::CLI.doctor_scan_containers,
      Kyb::CLI.doctor_scan_volumes(Kyb::CLI.doctor_scan_containers)) }
    assert_includes removed, 'kyb-orphan-volume'
    refute_includes removed, 'kyb-gradle-cache'
  end
  def test_empty
    orig = Kyb::CLI.method(:doctor_ps_raw)
    Kyb::CLI.define_singleton_method(:doctor_ps_raw) { [] }
    assert_empty Kyb::CLI.doctor_scan_containers
  ensure
    Kyb::CLI.define_singleton_method(:doctor_ps_raw, orig)
  end
end
