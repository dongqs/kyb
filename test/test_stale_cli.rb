require_relative 'test_helper'

class StaleCLITest < Minitest::Test
  def setup
    @_orig_load = Kyb::Config.method(:load) rescue nil
    Kyb::Config.define_singleton_method(:load) { nil }
    # CLITest.teardown removes singleton methods via remove_method,
    # which can permanently remove module_function methods.
    # Reload to restore them, suppressing constant redefinition warnings.
    verbose = $VERBOSE
    $VERBOSE = nil
    load File.expand_path('../lib/kyb/cli/create.rb', __dir__)
    load File.expand_path('../lib/kyb/cli/enter.rb', __dir__)
    $VERBOSE = verbose
  end

  def teardown
    Kyb::Config.singleton_class.remove_method(:load) rescue nil
    Kyb::Config.define_singleton_method(:load, @_orig_load) if @_orig_load
  end

  def stub_project
    Kyb::Config.stub(:project, ->(name) {
      { name: name, path: '/tmp/test-project', base_branch: 'master',
        dockerfile: nil, ports: [], symlinks: '', mounts_rw: '', mounts_ro: '',
        extra_prompt: nil, timezone: 'Asia/Shanghai',
        proxy: nil, no_proxy: nil }
    }) do
      yield
    end
  end

  # --- create ---

  def test_create_no_warning_when_image_fresh
    Kyb::Docker.stub(:create_container, ['kyb-niao-kyb', '']) do
      Kyb::Docker.stub(:image_exists?, true) do
        Kyb::Docker.stub(:stale?, false) do
          Kyb::Config.stub(:base_image_path, '/tmp') do
            stub_project do
              out, _ = capture_io do
                Kyb::CLI.create('niao', 'kyb')
              end
              refute_match(/outdated/, out)
            end
          end
        end
      end
    end
  end

  def test_create_warns_when_image_stale_and_timeout
    Kyb::Docker.stub(:create_container, ['kyb-niao-kyb', '']) do
      Kyb::Docker.stub(:image_exists?, true) do
        Kyb::Docker.stub(:stale?, true) do
          Kyb::Config.stub(:base_image_path, '/tmp') do
            # IO.select returns nil → 5s timeout, auto-continue
            IO.stub(:select, nil) do
              stub_project do
                out, _ = capture_io do
                  Kyb::CLI.create('niao', 'kyb')
                end
                assert_match(/outdated/, out)
                assert_match(/Container ready/, out)
              end
            end
          end
        end
      end
    end
  end

  def test_create_warns_and_aborts_on_n
    Kyb::Docker.stub(:create_container, ['kyb-niao-kyb', '']) do
      Kyb::Docker.stub(:image_exists?, true) do
        Kyb::Docker.stub(:stale?, true) do
          Kyb::Config.stub(:base_image_path, '/tmp') do
            fake_stdin = StringIO.new("n\n")
            IO.stub(:select, [[fake_stdin]]) do
              STDIN.stub(:gets, 'n') do
                stub_project do
                  assert_raises(SystemExit) do
                    capture_io { Kyb::CLI.create('niao', 'kyb') }
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  # --- enter ---

  def test_enter_no_warning_when_image_fresh
    Kyb::Docker.stub(:running?, true) do
      Kyb::Docker.stub(:image_exists?, true) do
        Kyb::Docker.stub(:stale?, false) do
          Kyb::Config.stub(:base_image_path, '/tmp') do
            Kyb::CLI.stub(:system, true) do
              Kyb::CLI.stub(:exec, nil) do
                stub_project do
                  out, _ = capture_io do
                    Kyb::CLI.enter('niao', 'kyb')
                  end
                  refute_match(/outdated/, out)
                end
              end
            end
          end
        end
      end
    end
  end

  def test_enter_injects_stale_msg_into_prompt
    Kyb::Docker.stub(:running?, true) do
      Kyb::Docker.stub(:image_exists?, true) do
        Kyb::Docker.stub(:stale?, true) do
          Kyb::Config.stub(:base_image_path, '/tmp') do
            IO.stub(:select, nil) do
              Kyb::CLI.stub(:system, true) do
                Kyb::CLI.stub(:exec, nil) do
                  stub_project do
                    out, _ = capture_io do
                      Kyb::CLI.enter('niao', 'kyb')
                    end
                    assert_match(/outdated/, out)
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
