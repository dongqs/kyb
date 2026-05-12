require_relative 'test_helper'

class DockerTest < Minitest::Test
  # --- container_name ---

  def test_container_name_without_suffix
    assert_equal 'dev-niao', Kyb::Docker.container_name('niao')
  end

  def test_container_name_with_suffix
    assert_equal 'dev-niao-water', Kyb::Docker.container_name('niao', 'water')
  end

  def test_container_name_suffix_nil
    assert_equal 'dev-niao', Kyb::Docker.container_name('niao', nil)
  end

  # --- port_in_use? ---

  def test_port_not_in_use
    refute Kyb::Docker.port_in_use?(29_001)
  end

  def test_port_in_use
    server = TCPServer.new('0.0.0.0', 29_002)
    assert Kyb::Docker.port_in_use?(29_002)
  ensure
    server&.close
  end

  # --- assign_ports ---

  def test_assign_ports_single_when_free
    mapping = Kyb::Docker.assign_ports([29_100])
    assert_equal '29100:29100', mapping
  end

  def test_assign_ports_multiple_when_all_free
    mapping = Kyb::Docker.assign_ports([29_200, 29_201])
    assert_equal '29200:29200,29201:29201', mapping
  end

  def test_assign_ports_skips_busy_port
    server = TCPServer.new('0.0.0.0', 29_300)
    mapping = Kyb::Docker.assign_ports([29_300])
    assert_equal '29301:29300', mapping
  ensure
    server&.close
  end

  def test_assign_ports_multiple_with_one_busy
    server = TCPServer.new('0.0.0.0', 29_400)
    mapping = Kyb::Docker.assign_ports([29_400, 29_500])
    assert_equal '29401:29400,29500:29500', mapping
  ensure
    server&.close
  end

  def test_assign_ports_empty_array
    assert_equal '', Kyb::Docker.assign_ports([])
  end
end
