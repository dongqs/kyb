require_relative 'test_helper'

class DIDTest < Minitest::Test
  def setup
    skip 'DID tests require Docker (CI)' if ENV['CI']
  end


  def test_did_create_refuses_nesting
    ENV['KYB_DID'] = 'inner'
    assert_raises(SystemExit) { capture_io { Kyb::CLI.did_create(['nested']) } }
  ensure
    ENV.delete('KYB_DID')
  end

  def test_did_create_refuses_when_no_env
    ENV.delete('KYB_PROJECT')
    ENV.delete('KYB_BRANCH')
    assert_raises(SystemExit) { capture_io { Kyb::CLI.did_create(['orphan']) } }
  end
end
