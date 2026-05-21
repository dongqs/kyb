require_relative 'test_helper'

class KybTest < Minitest::Test
  def test_in_container_returns_true_when_dockerenv_exists
    File.stub(:exist?, ->(path) { path == '/.dockerenv' }) do
      assert Kyb.in_container?
    end
  end
  def test_in_container_returns_false_when_dockerenv_absent
    File.stub(:exist?, ->(_path) { false }) do
      refute Kyb.in_container?
    end
  end
  def test_proxy_docker_container_delegates_to_in_container
    File.stub(:exist?, ->(path) { path == '/.dockerenv' }) do
      assert Kyb::Proxy.docker_container?
    end
  end
  def test_proxy_docker_container_false_outside_container
    File.stub(:exist?, ->(_path) { false }) do
      refute Kyb::Proxy.docker_container?
    end
  end
  def test_tts_containerized_delegates_to_in_container
    File.stub(:exist?, ->(path) { path == '/.dockerenv' }) do
      assert Kyb::CLI.containerized?
    end
  end
  def test_tts_containerized_false_outside_container
    File.stub(:exist?, ->(_path) { false }) do
      refute Kyb::CLI.containerized?
    end
  end
end
