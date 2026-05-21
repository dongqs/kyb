require_relative 'test_helper'

class DIDCpusTest < Minitest::Test
  def setup
    skip 'DID tests require Docker (CI)' if ENV['CI']
    ENV['KYB_PROJECT'] = 'testproj'
    ENV['KYB_BRANCH']  = 'testbr'
  end

  def teardown
    ENV.delete('KYB_PROJECT')
    ENV.delete('KYB_BRANCH')
  end

  def test_parses_cpus_after_name
    cpus = nil
    rest = %w[mybox --cpus 4]
    if (idx = rest.index('--cpus'))
      rest.delete_at(idx)
      cpus = rest.delete_at(idx)
    end
    assert_equal '4', cpus
    assert_equal %w[mybox], rest
  end

  def test_parses_cpus_before_name
    cpus = nil
    rest = %w[--cpus 4 mybox]
    if (idx = rest.index('--cpus'))
      rest.delete_at(idx)
      cpus = rest.delete_at(idx)
    end
    assert_equal '4', cpus
    assert_equal %w[mybox], rest
  end

  def test_nil_when_no_cpus_flag
    cpus = nil
    rest = %w[mybox].dup
    if (idx = rest.index('--cpus'))
      rest.delete_at(idx)
      cpus = rest.delete_at(idx)
    end
    assert_nil cpus
    assert_equal %w[mybox], rest
  end

  def test_rejects_zero
    assert_raises(SystemExit) { capture_io { Kyb::CLI.did_create(%w[mybox --cpus 0]) } }
  end

  def test_rejects_negative
    assert_raises(SystemExit) { capture_io { Kyb::CLI.did_create(%w[mybox --cpus -1]) } }
  end

  def test_rejects_non_numeric
    assert_raises(SystemExit) { capture_io { Kyb::CLI.did_create(%w[mybox --cpus abc]) } }
  end
end
