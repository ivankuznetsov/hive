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

  # ── `hive web install` orchestration ────────────────────────────────
  # install_service maps the installer outcome onto the CLI error contract:
  # a drifted unit → InvalidTaskPath (retry with --force), a failed install →
  # Hive::Error, and --json emits the hive-web-install envelope. Swap in a fake
  # installer so the mapping is asserted without touching launchctl/systemctl.
  def with_fake_web_installer(outcome_kind)
    require "hive/commands/web/service_installer"
    require "hive/commands/service_installer/outcome"
    outcome = Hive::Commands::ServiceInstaller::Outcome.new(outcome_kind)
    fake = Class.new do
      define_method(:initialize) { |binary_path: nil| }
      define_method(:install!) { |autostart:, force:| outcome }
      define_method(:messages) { [ "installed note" ] }
      define_method(:target_path) { "/tmp/local.hive-web.plist" }
      define_method(:envelope_platform) { "macos" }
    end
    original = Hive::Commands::Web.const_get(:ServiceInstaller)
    Hive::Commands::Web.send(:remove_const, :ServiceInstaller)
    Hive::Commands::Web.const_set(:ServiceInstaller, fake)
    begin
      yield
    ensure
      Hive::Commands::Web.send(:remove_const, :ServiceInstaller)
      Hive::Commands::Web.const_set(:ServiceInstaller, original)
    end
  end

  def test_install_service_maps_drift_to_invalid_task_path
    with_tmp_global_config do
      with_fake_web_installer(:drifted) do
        assert_raises(Hive::InvalidTaskPath) do
          capture_io { Hive::Commands::Web.new("install", no_bootstrap: true).call }
        end
      end
    end
  end

  def test_install_service_maps_failure_to_error
    with_tmp_global_config do
      with_fake_web_installer(:failed) do
        error = assert_raises(Hive::Error) do
          capture_io { Hive::Commands::Web.new("install", no_bootstrap: true).call }
        end
        refute_instance_of Hive::InvalidTaskPath, error,
                           "a failed install is a hard error, not a retry-with-force drift"
      end
    end
  end

  def test_install_service_json_envelope_shape
    with_tmp_global_config do
      with_fake_web_installer(:written) do
        out, = capture_io { Hive::Commands::Web.new("install", no_bootstrap: true, json: true).call }
        payload = JSON.parse(out)
        assert_equal "hive-web-install", payload["schema"]
        assert_equal true, payload["ok"]
        assert_equal "written", payload["outcome"]
        assert_equal "macos", payload["platform"]
        assert_equal "/tmp/local.hive-web.plist", payload["target_path"]
        assert payload.key?("backup_path"), "envelope must carry backup_path"
        assert payload.key?("restarted"), "envelope must carry restarted"
        assert_kind_of Array, payload["messages"]
      end
    end
  end

  # ── loopback no-auth env export matrix ──────────────────────────────
  # `call` sets HIVEBOX_LOCAL_LOOPBACK=1 only when the bind is loopback AND
  # web.local_loopback is still true; the Rails side trusts that env var to
  # enable the no-auth bypass, so the CLI must export it exactly in that case.
  def captured_exec_env(bind:, unsafe: false, web_config: nil)
    caught = nil
    with_tmp_global_config do |dir|
      if web_config
        File.write(File.join(dir, "config.yml"),
                   { "registered_projects" => [], "web" => web_config }.to_yaml)
      end
      with_stub_rails_app(prepare_exit: 0) do
        original = Kernel.method(:exec)
        Kernel.define_singleton_method(:exec) { |env, *argv| raise ExecCaught.new(env, argv) }
        begin
          capture_io { Hive::Commands::Web.new(bind: bind, unsafe: unsafe).call }
        rescue ExecCaught => e
          caught = e
        ensure
          Kernel.define_singleton_method(:exec, original)
        end
      end
    end
    caught&.env || {}
  end

  def test_loopback_env_set_on_loopback_bind_with_default_config
    assert_equal "1", captured_exec_env(bind: "127.0.0.1")["HIVEBOX_LOCAL_LOOPBACK"],
                 "a loopback bind with local_loopback enabled must signal the no-auth bypass"
  end

  def test_loopback_env_omitted_on_non_loopback_bind
    refute captured_exec_env(bind: "0.0.0.0", unsafe: true).key?("HIVEBOX_LOCAL_LOOPBACK"),
           "a non-loopback bind must never signal the loopback bypass"
  end

  def test_loopback_env_omitted_when_config_opts_out
    refute captured_exec_env(bind: "127.0.0.1", web_config: { "local_loopback" => false })
           .key?("HIVEBOX_LOCAL_LOOPBACK"),
           "web.local_loopback:false must suppress the bypass even on a loopback bind"
  end
end
