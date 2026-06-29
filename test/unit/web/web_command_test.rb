require "test_helper"
require "hive/commands/web"

class WebCommandTest < Minitest::Test
  include HiveTestHelper

  # `hive web` now boots the Rails app under web/; outside the container or
  # a source checkout (no web/ dir, no HIVEBOX_WEB_APP_DIR) it must fail
  # loudly with guidance instead of exec-ing into a missing app.
  def test_missing_rails_app_exits_with_guidance
    with_tmp_global_config do
      with_env("HIVEBOX_WEB_APP_DIR" => File.join(Dir.mktmpdir("hive-noapp"), "nope")) do
        command = Hive::Commands::Web.new
        # Singleton override instead of minitest/mock (not bundled): the
        # checkout itself contains web/, so the fallback path would resolve.
        command.define_singleton_method(:rails_app_dir) { |**| nil }
        err = assert_raises(SystemExit) do
          capture_io { command.call }
        end
        assert_equal 1, err.status, "a missing web app must exit 1"
      end
    end
  end

  def test_rails_app_dir_honours_env_override
    Dir.mktmpdir("hive-webapp") do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "# rails app marker")
      with_env("HIVEBOX_WEB_APP_DIR" => dir) do
        command = Hive::Commands::Web.new
        assert_equal dir, command.send(:rails_app_dir),
                     "HIVEBOX_WEB_APP_DIR must take precedence when it holds a Rails app"
      end
    end
  end

  def test_public_bind_without_https_origin_warns
    with_tmp_global_config do
      command = Hive::Commands::Web.new
      _out, err = capture_io do
        command.send(:warn_on_public_bind, "0.0.0.0", { "origin" => "http://example.test" })
      end
      assert_match(/WARNING binding 0.0.0.0/, err, "plain-http public bind must warn about Host validation")

      _out, err = capture_io do
        command.send(:warn_on_public_bind, "0.0.0.0", { "origin" => "https://example.test" })
      end
      assert_empty err, "an https origin implies a fronting proxy — no warning"
    end
  end
  # Drive the full "app found" path with a stub Rails app: db:prepare
  # failure raises typed guidance (never a raw backtrace looping under the
  # container supervisor), and a passing prepare reaches Kernel.exec with
  # the bind/port argv.
  class ExecCaught < StandardError
    attr_reader :env, :argv

    def initialize(env, argv)
      @env = env
      @argv = argv
      super("exec")
    end
  end

  def with_stub_rails_app(prepare_exit:)
    Dir.mktmpdir("hive-webapp") do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "# rails app marker")
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin", "rails"), <<~SH)
        #!/usr/bin/env bash
        [ "$1" = "db:prepare" ] && exit #{prepare_exit}
        exit 0
      SH
      FileUtils.chmod(0o755, File.join(dir, "bin", "rails"))
      with_env("HIVEBOX_WEB_APP_DIR" => dir) do
        yield dir
      end
    end
  end

  def test_db_prepare_failure_raises_typed_guidance
    with_tmp_global_config do
      with_stub_rails_app(prepare_exit: 1) do
        error = assert_raises(Hive::Error) do
          capture_io { Hive::Commands::Web.new.call }
        end
        assert_match(/db:prepare failed/, error.message)
        assert_match(/writable/, error.message, "the message must point at the /data mount")
      end
    end
  end

  def test_successful_boot_reaches_exec_with_bind_and_port
    with_tmp_global_config do
      with_stub_rails_app(prepare_exit: 0) do
        original = Kernel.method(:exec)
        Kernel.define_singleton_method(:exec) do |env, *argv|
          raise ExecCaught.new(env, argv)
        end

        caught = nil
        begin
          capture_io { Hive::Commands::Web.new.call }
        rescue ExecCaught => e
          caught = e
        ensure
          Kernel.define_singleton_method(:exec, original)
        end

        refute_nil caught, "the command must end in Kernel.exec of the rails server"
        assert_equal %w[bin/rails server -b], caught.argv[0..2]
        assert caught.env.key?("SECRET_KEY_BASE"), "the persisted session secret must reach Rails"
        assert caught.env.key?("HIVEBOX_STORAGE_DIR")
      end
    end
  end
end
