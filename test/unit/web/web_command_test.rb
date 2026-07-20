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
        # A HIVEBOX_WEB_APP_DIR override (like the hivebox image's baked
        # /app/web) was bundle-installed against its own ".." — exporting
        # HIVE_CLI_ROOT would re-point the Gemfile's path source and
        # invalidate that prebuilt bundle (the v0.3.4/v0.3.5 image-smoke
        # db:prepare failure). Only the managed bundle gets the export.
        refute caught.env.key?("HIVE_CLI_ROOT"),
               "an operator-managed app dir must not have its path-gem source re-pointed"
      end
    end
  end

  def test_relative_env_override_exec_env_uses_absolute_gemfile
    with_tmp_global_config do
      Dir.mktmpdir("hive-web-parent") do |parent|
        app_name = "relapp"
        app_dir = File.join(parent, app_name)
        FileUtils.mkdir_p(File.join(app_dir, "config"))
        File.write(File.join(app_dir, "config", "application.rb"), "# rails app marker")
        File.write(File.join(app_dir, "Gemfile"), "# test gemfile")
        FileUtils.mkdir_p(File.join(app_dir, "bin"))
        File.write(File.join(app_dir, "bin", "rails"), "#!/usr/bin/env bash\nexit 0\n")
        FileUtils.chmod(0o755, File.join(app_dir, "bin", "rails"))

        original = Kernel.method(:exec)
        caught = nil
        Dir.chdir(parent) do
          with_env("HIVEBOX_WEB_APP_DIR" => app_name) do
            Kernel.define_singleton_method(:exec) do |env, *argv|
              raise ExecCaught.new(env, argv)
            end

            begin
              capture_io { Hive::Commands::Web.new.call }
            rescue ExecCaught => e
              caught = e
            ensure
              Kernel.define_singleton_method(:exec, original)
            end
          end
        end

        refute_nil caught, "the command must reach Kernel.exec for a relative app override"
        assert_equal File.join(app_dir, "Gemfile"), caught.env["BUNDLE_GEMFILE"]
      end
    end
  end

  # The MANAGED bundle is the one place whose Gemfile can only resolve the
  # hive-cli path gem through HIVE_CLI_ROOT (its ".." holds no gem, and its
  # bundle was installed with the same export). The Rails server re-evaluates
  # the Gemfile at boot, so the exec env must carry it there — and only there.
  def test_managed_bundle_exec_env_carries_hive_cli_root
    with_tmp_global_config do
      dir = Hive::Web::AppBundle.app_dir
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "# rails app marker")
      File.write(File.join(dir, Hive::Web::AppBundle::VERSION_FILE), "#{Hive::VERSION}\n")
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin", "rails"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(dir, "bin", "rails"))

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
      assert_equal Hive::Web::AppBundle.hive_cli_root, caught.env["HIVE_CLI_ROOT"]
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
      define_method(:service_state) do
        {
          "platform" => "macos", "unit_path" => "/tmp/local.hive-web.plist",
          "service_installed" => true, "service_enabled" => false,
          "service_running" => false, "service_manager_available" => true
        }
      end
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
        assert_equal 1, payload["schema_version"]
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

  # ── service subcommand routing (install|start|stop|status) ──────────
  # The `service_command` dispatcher plus the launchctl/systemctl action
  # runner and the status/service envelopes. A fresh ServiceInstaller with a
  # stubbed platform + target_path drives the argv branch, and `system` is
  # stubbed to capture the exact command without touching the host.

  # Build a Web command whose #run_service_action / #status_service internal
  # `ServiceInstaller.new(...)` yields a fake reporting the given platform.
  def with_fake_service_installer(platform:, target_path: "/tmp/hive-web.service",
                                  service_name: "hive-web", state: nil)
    require "hive/commands/web/service_installer"
    fake = Object.new
    fake.define_singleton_method(:envelope_platform) { platform }
    fake.define_singleton_method(:target_path) { target_path }
    fake.define_singleton_method(:service_name) { service_name }
    fake.define_singleton_method(:service_state) { state || { "service_installed" => false } }
    original = Hive::Commands::Web.const_get(:ServiceInstaller)
    Hive::Commands::Web.send(:remove_const, :ServiceInstaller)
    Hive::Commands::Web.const_set(:ServiceInstaller, Class.new do
      define_singleton_method(:new) { |*_a, **_kw| fake }
    end)
    begin
      yield fake
    ensure
      Hive::Commands::Web.send(:remove_const, :ServiceInstaller)
      Hive::Commands::Web.const_set(:ServiceInstaller, original)
    end
  end

  def capture_system_argv(command)
    calls = []
    command.define_singleton_method(:system) do |*argv|
      calls << argv
      true
    end
    calls
  end

  def test_start_service_on_macos_issues_launchctl_load
    command = Hive::Commands::Web.new("start", detach: true)
    calls = capture_system_argv(command)
    with_fake_service_installer(platform: "macos", target_path: "/plist") do
      command.call
    end
    assert_equal [ [ "launchctl", "load", "/plist" ] ], calls,
                 "start on macOS must launchctl load the target plist"
  end

  def test_stop_service_on_macos_issues_launchctl_unload
    command = Hive::Commands::Web.new("stop")
    calls = capture_system_argv(command)
    with_fake_service_installer(platform: "macos", target_path: "/plist") do
      command.call
    end
    assert_equal [ [ "launchctl", "unload", "/plist" ] ], calls
  end

  def test_start_service_on_linux_reloads_then_starts_unit
    command = Hive::Commands::Web.new("start", detach: true)
    calls = capture_system_argv(command)
    with_fake_service_installer(platform: "linux", service_name: "hive-web") do
      command.call
    end
    assert_equal [ %w[systemctl --user daemon-reload],
                   %w[systemctl --user start hive-web] ], calls,
                 "linux start must daemon-reload before starting so a freshly written unit is visible"
  end

  def test_stop_service_on_linux_does_not_reload
    command = Hive::Commands::Web.new("stop")
    calls = capture_system_argv(command)
    with_fake_service_installer(platform: "linux", service_name: "hive-web") do
      command.call
    end
    assert_equal [ %w[systemctl --user stop hive-web] ], calls,
                 "stop must not daemon-reload; only start needs the freshly-written-unit reload"
  end

  def test_run_service_action_raises_when_system_fails
    command = Hive::Commands::Web.new("stop")
    command.define_singleton_method(:system) { |*_argv| false }
    error = with_fake_service_installer(platform: "linux") do
      assert_raises(Hive::Error) { command.call }
    end
    assert_match(/could not stop managed service/, error.message)
  end

  def test_start_without_detach_falls_through_to_foreground_call
    # `start` sans --detach dispatches to the foreground boot path. Stub
    # rails_app_dir → nil so it exits 1 with guidance rather than exec-ing a
    # real server; the point is that it took the foreground branch, not
    # start_service.
    with_tmp_global_config do
      command = Hive::Commands::Web.new("start")
      command.define_singleton_method(:rails_app_dir) { |**| nil }
      command.define_singleton_method(:system) { |*_argv| flunk "start (no --detach) must not run a service action" }
      err = assert_raises(SystemExit) { capture_io { command.call } }
      assert_equal 1, err.status
    end
  end

  def test_unknown_subcommand_raises_invalid_task_path
    error = assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::Web.new("frobnicate", no_bootstrap: true).call
    end
    assert_match(/unknown subcommand "frobnicate"/, error.message)
    assert_match(/install, start, stop, status/, error.message)
  end

  def test_status_service_text_reports_installed_state
    command = Hive::Commands::Web.new("status")
    out, = with_fake_service_installer(platform: "linux", state: { "service_installed" => true }) do
      capture_io { command.call }
    end
    assert_match(/service installed/, out)
  end

  def test_status_service_json_emits_status_envelope
    command = Hive::Commands::Web.new("status", json: true)
    state = {
      "platform" => "linux", "service_installed" => true, "service_enabled" => false,
      "service_running" => false, "service_manager_available" => true
    }
    out, = with_fake_service_installer(platform: "linux", state: state) do
      capture_io { command.call }
    end
    payload = JSON.parse(out)
    assert_equal "hive-web-status", payload["schema"]
    assert_equal 1, payload["schema_version"]
    assert_equal true, payload["ok"]
    assert_equal true, payload["service_installed"], "the installer's service_state must be merged into the envelope"
    assert_equal false, payload["service_running"]
    assert_equal false, payload["ready"]
    assert_equal "disabled", payload["readiness"]
  end

  # ── rails_app_dir resolution + bootstrap ────────────────────────────
  # The managed bundle takes precedence over a source checkout; bootstrap:true
  # refreshes it via ensure!, bootstrap:false returns the on-disk app_dir.
  def test_rails_app_dir_prefers_managed_bundle_and_refreshes_when_bootstrapping
    command = Hive::Commands::Web.new
    ensure_called = false
    with_replaced_singleton_method(Hive::Web::AppBundle, :present?, ->(*) { true }) do
      with_replaced_singleton_method(Hive::Web::AppBundle, :ensure!, ->(*) { ensure_called = true; "/managed" }) do
        assert_equal "/managed", command.send(:rails_app_dir, bootstrap: true)
      end
    end
    assert ensure_called, "bootstrap:true must call ensure! to refresh a present-but-maybe-stale bundle"
  end

  def test_rails_app_dir_returns_managed_app_dir_without_bootstrap
    command = Hive::Commands::Web.new
    with_replaced_singleton_method(Hive::Web::AppBundle, :present?, ->(*) { true }) do
      with_replaced_singleton_method(Hive::Web::AppBundle, :ensure!, ->(*) { flunk "bootstrap:false must not call ensure!" }) do
        with_replaced_singleton_method(Hive::Web::AppBundle, :app_dir, ->(*) { "/managed-nostale" }) do
          assert_equal "/managed-nostale", command.send(:rails_app_dir, bootstrap: false)
        end
      end
    end
  end

  def test_rails_app_dir_uses_source_checkout_when_no_managed_bundle
    command = Hive::Commands::Web.new
    with_replaced_singleton_method(Hive::Web::AppBundle, :present?, ->(*) { false }) do
      # The checkout itself contains web/config/application.rb, so the source
      # candidate resolves and is returned verbatim (no bootstrap).
      dir = command.send(:rails_app_dir, bootstrap: false)
      refute_nil dir, "a source checkout's web/ dir must be used when no managed bundle exists"
      assert File.file?(File.join(dir, "config", "application.rb")),
             "the resolved source dir must actually hold a Rails app"
    end
  end

  def test_rails_app_dir_returns_nil_without_bundle_source_or_bootstrap
    command = Hive::Commands::Web.new
    original_file = File.method(:file?)
    with_replaced_singleton_method(Hive::Web::AppBundle, :present?, ->(*) { false }) do
      # No managed bundle AND make the source-checkout application.rb marker
      # miss, so with bootstrap:false the method reaches its final `nil` branch.
      with_replaced_singleton_method(File, :file?, lambda { |path|
        path.end_with?("web/config/application.rb") ? false : original_file.call(path)
      }) do
        assert_nil command.send(:rails_app_dir, bootstrap: false),
                   "no bundle, no source app, bootstrap:false must resolve to nil"
      end
    end
  end
end
