require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'

class StaleIntegrationTest < Minitest::Test
  TEST_TAG = 'kyb-test-stale'

  def setup
    unless docker_available?
      skip 'Docker not available in this environment'
    end
    @tmpdir = Dir.mktmpdir('kyb-stale-test-')
    @dfile = File.join(@tmpdir, 'Dockerfile')
    write_dockerfile('FROM busybox:stable', 'RUN echo first > /tmp/v1.txt')
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    system('docker', 'rmi', '-f', TEST_TAG, out: File::NULL, err: File::NULL)
    # Clean up any stale-check tags left behind
    tags = `docker images --format '{{.Repository}}:{{.Tag}}' #{TEST_TAG}`.lines.map(&:strip)
    tags.each { |t| system('docker', 'rmi', '-f', t, out: File::NULL, err: File::NULL) }
  end

  def write_dockerfile(*lines)
    File.write(@dfile, lines.join("\n") + "\n")
  end

  def docker_available?
    system('docker', 'info', out: File::NULL, err: File::NULL)
  end

  def build_base
    _, err = capture_io do
      system({ 'DOCKER_BUILDKIT' => '1' },
             'docker', 'build', '-t', TEST_TAG, @tmpdir.to_s,
             out: File::NULL, err: File::NULL)
    end
    assert system('docker', 'image', 'inspect', TEST_TAG, out: File::NULL, err: File::NULL),
           "base image #{TEST_TAG} should exist after build"
  end

  def test_stale_returns_false_when_nothing_changed
    build_base
    result = nil
    capture_io do
      result = Kyb::Docker.stale?(TEST_TAG, @tmpdir)
    end
    refute result, 'should not be stale when Dockerfile unchanged'
  end

  def test_stale_returns_true_when_dockerfile_changed
    build_base
    write_dockerfile('FROM busybox:stable', 'RUN echo second > /tmp/v2.txt')
    result = nil
    capture_io do
      result = Kyb::Docker.stale?(TEST_TAG, @tmpdir)
    end
    assert result, 'should be stale when Dockerfile changed'
  end

  def test_stale_cleans_up_temp_tags
    build_base
    capture_io do
      Kyb::Docker.stale?(TEST_TAG, @tmpdir)
    end
    tags = `docker images --format '{{.Repository}}:{{.Tag}}' #{TEST_TAG}`.lines.map(&:strip)
    stale_tags = tags.select { |t| t.include?('stale-check') }
    assert_empty stale_tags, "expected no stale-check tags, got: #{stale_tags.join(', ')}"
  end

  def test_stale_no_base_image_does_not_crash
    # Ensure the tag does NOT exist by using a fresh one
    fresh_tag = 'kyb-test-stale-nonexistent'
    system('docker', 'rmi', '-f', fresh_tag, out: File::NULL, err: File::NULL)
    result = nil
    capture_io do
      result = Kyb::Docker.stale?(fresh_tag, @tmpdir)
    end
    # Without a base image, every layer is built — so stale? returns true
    # But more importantly: no crash, no hang.
    assert_includes [true, false], result
  ensure
    system('docker', 'rmi', '-f', fresh_tag, out: File::NULL, err: File::NULL)
  end
end
