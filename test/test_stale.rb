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
  end

  def write_dockerfile(*lines)
    File.write(@dfile, lines.join("\n") + "\n")
  end

  def docker_available?
    system('timeout', '3', 'docker', 'info', out: File::NULL, err: File::NULL)
  end

  def build_base
    hash = Kyb::Docker.compute_build_hash(@tmpdir)
    system({ 'DOCKER_BUILDKIT' => '1' },
           'docker', 'build', '-t', TEST_TAG,
           '--label', "kyb.build-hash=#{hash}",
           @tmpdir.to_s,
           out: File::NULL, err: File::NULL)
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

  def test_stale_returns_false_for_unlabeled_image
    build_base
    system({ 'DOCKER_BUILDKIT' => '1' },
           'docker', 'build', '-t', "#{TEST_TAG}-unlabeled",
           @tmpdir.to_s,
           out: File::NULL, err: File::NULL)
    result = nil
    capture_io do
      result = Kyb::Docker.stale?("#{TEST_TAG}-unlabeled", @tmpdir)
    end
    refute result, 'unlabeled image should return false (conservative)'
  ensure
    system('docker', 'rmi', '-f', "#{TEST_TAG}-unlabeled", out: File::NULL, err: File::NULL)
  end

  def test_stale_no_base_image_does_not_crash
    fresh_tag = 'kyb-test-stale-nonexistent'
    system('docker', 'rmi', '-f', fresh_tag, out: File::NULL, err: File::NULL)
    result = nil
    capture_io do
      result = Kyb::Docker.stale?(fresh_tag, @tmpdir)
    end
    refute result, 'nonexistent image should not crash and return false'
  ensure
    system('docker', 'rmi', '-f', fresh_tag, out: File::NULL, err: File::NULL)
  end
end
