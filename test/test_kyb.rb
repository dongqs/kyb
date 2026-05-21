require_relative 'test_helper'
class KybTest < Minitest::Test
  def test_in_container_true
    File.stub(:exist?, ->(p) { p == '/.dockerenv' }) { assert Kyb.in_container? }
  end
  def test_in_container_false
    File.stub(:exist?, ->(p) { false }) { refute Kyb.in_container? }
  end
  def test_proxy_container_detection
    File.stub(:exist?, ->(p) { p == '/.dockerenv' }) { assert Kyb::Proxy.docker_container? }
  end
  def test_tts_container_detection
    File.stub(:exist?, ->(p) { p == '/.dockerenv' }) { assert Kyb::CLI.containerized? }
  end
end
