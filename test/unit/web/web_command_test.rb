require "test_helper"
require "hive/commands/web"
require "hive/commands/service_installer/outcome"

class WebCommandTest < Minitest::Test
  include HiveTestHelper

  # `hive web` now boots the Rails app under web/; outside the container or
  # a source checkout (no web/ dir, no HIVE_WEB_APP_DIR) it must fail
  # loudly with guidance instead of exec-ing into a missing app.
  def test_missing_rails_app_exits_with_guidance
    with_tmp_global_config do
      with_env("HIVE_WEB_APP_DIR" => File.join(Dir.mktmpdir("hive-noapp"), "nope")) do
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

  def test_rails_app_dir_honours_legacy_env_override
    Dir.mktmpdir("hive-webapp") do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "# rails app marker")
      with_env("HIVEBOX_WEB_APP_DIR" => dir) do
        command = Hive::Commands::Web.new
        assert_equal dir, command.send(:rails_app_dir),
                     "the HIVEBOX_WEB_APP_DIR compatibility alias must still select a Rails app"
      end
    end
  end

  def test_canonical_app_dir_wins_over_legacy_alias
    Dir.mktmpdir("hive-web-new") do |canonical|
      Dir.mktmpdir("hive-web-old") do |legacy|
        [ canonical, legacy ].each do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config", "application.rb"), "# rails app marker")
        end
        error = StringIO.new
        command = Hive::Commands::Web.new(
          environment: {
            "HIVE_WEB_APP_DIR" => canonical,
            "HIVEBOX_WEB_APP_DIR" => legacy
          },
          error: error
        )

        assert_equal canonical, command.send(:rails_app_dir)
        assert_empty error.string
      end
    end
  end

  def test_invalid_canonical_app_dir_does_not_fall_back_to_valid_legacy_alias
    Dir.mktmpdir("hive-web-old") do |legacy|
      FileUtils.mkdir_p(File.join(legacy, "config"))
      File.write(File.join(legacy, "config", "application.rb"), "# rails app marker")
      command = Hive::Commands::Web.new(
        environment: {
          "HIVE_WEB_APP_DIR" => "/missing/canonical-hive-web",
          "HIVEBOX_WEB_APP_DIR" => legacy
        }
      )

      error = assert_raises(Hive::Error) { command.send(:rails_app_dir) }
      assert_includes error.message, "HIVE_WEB_APP_DIR"
      assert_includes error.message, "/missing/canonical-hive-web"
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
        if [ "$1" = "assets:precompile" ]; then
          mkdir -p public/assets
          printf 'body {}\n' > public/assets/application-test.css
          printf 'export {}\n' > public/assets/application-test.js
          printf '%s\n' '{"application.css":{"digested_path":"application-test.css"},"application.js":{"digested_path":"application-test.js"}}' > public/assets/.manifest.json
          exit 0
        fi
        [ "$1" = "db:prepare" ] && exit #{prepare_exit}
        exit 0
      SH
      FileUtils.chmod(0o755, File.join(dir, "bin", "rails"))
      with_env("HIVE_WEB_APP_DIR" => dir) do
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
        assert caught.env.key?("HIVE_WEB_STORAGE_DIR")
        # A HIVE_WEB_APP_DIR override (like the Hivebox image's baked
        # /app/web) was bundle-installed against its own ".." — exporting
        # HIVE_CLI_ROOT would re-point the Gemfile's path source and
        # invalidate that prebuilt bundle (the v0.3.4/v0.3.5 image-smoke
        # db:prepare failure). Only the managed bundle gets the export.
        refute caught.env.key?("HIVE_CLI_ROOT"),
               "an operator-managed app dir must not have its path-gem source re-pointed"
        refute caught.env.key?("BUNDLE_PATH"),
               "an operator-managed app must keep the dependencies it was built against"
      end
    end
  end

  def test_production_boot_precompiles_assets_before_starting_rails
    with_tmp_global_config do
      with_stub_rails_app(prepare_exit: 0) do
        command = Hive::Commands::Web.new
        system_calls = []
        command.define_singleton_method(:system) do |*argv|
          system_calls << argv
          true
        end

        replacement = ->(env, *argv) { raise ExecCaught.new(env, argv) }
        caught = with_replaced_singleton_method(Kernel, :exec, replacement) do
          with_replaced_singleton_method(Hive::Web::AppBundle, :assets_ready?, ->(_dir) { true }) do
            assert_raises(ExecCaught) { capture_io { command.call } }
          end
        end

        rails_commands = system_calls.map { |call| call.last(2) }
        assert_equal [ %w[bin/rails assets:precompile], %w[bin/rails db:prepare] ], rails_commands,
                     "production boot must compile missing assets before preparing the database"
        precompile_env = system_calls.first.first
        refute_equal caught.env.fetch("HIVE_WEB_STORAGE_DIR"), precompile_env.fetch("HIVE_WEB_STORAGE_DIR"),
                     "asset compilation must not touch the live solid-stack databases"
        refute_path_exists precompile_env.fetch("HIVE_WEB_STORAGE_DIR"),
                           "temporary asset-build storage must be removed after compilation"
      end
    end
  end

  def test_production_boot_rejects_precompile_without_usable_assets
    with_tmp_global_config do
      with_stub_rails_app(prepare_exit: 0) do
        command = Hive::Commands::Web.new
        command.define_singleton_method(:system) { |*_argv| true }

        error = with_replaced_singleton_method(Hive::Web::AppBundle, :assets_ready?, ->(_dir) { false }) do
          assert_raises(Hive::Error) { capture_io { command.call } }
        end

        assert_match(/asset precompile failed/, error.message)
      end
    end
  end

  def test_production_boot_stops_when_asset_precompile_command_fails
    with_tmp_global_config do
      with_stub_rails_app(prepare_exit: 0) do
        command = Hive::Commands::Web.new
        system_calls = []
        command.define_singleton_method(:system) do |*argv|
          system_calls << argv
          argv.last(2) != %w[bin/rails assets:precompile]
        end

        error = with_replaced_singleton_method(Hive::Web::AppBundle, :assets_ready?, ->(_dir) { true }) do
          assert_raises(Hive::Error) { capture_io { command.call } }
        end

        assert_match(/asset precompile failed/, error.message)
        assert_equal [ %w[bin/rails assets:precompile] ], system_calls.map { |call| call.last(2) },
                     "a failed compiler must stop startup before db:prepare"
      end
    end
  end

  def test_development_boot_skips_asset_precompile
    with_tmp_global_config do
      with_stub_rails_app(prepare_exit: 0) do
        command = Hive::Commands::Web.new
        system_calls = []
        command.define_singleton_method(:system) do |*argv|
          system_calls << argv
          true
        end

        replacement = ->(env, *argv) { raise ExecCaught.new(env, argv) }
        with_replaced_singleton_method(Kernel, :exec, replacement) do
          with_env("RAILS_ENV" => "development") do
            assert_raises(ExecCaught) { capture_io { command.call } }
          end
        end

        assert_equal [ %w[bin/rails db:prepare] ], system_calls.map { |call| call.last(2) },
                     "development boot should leave asset compilation to the Rails development server"
      end
    end
  end

  def test_hivebox_boot_uses_assets_precompiled_into_the_image
    with_tmp_global_config do
      with_stub_rails_app(prepare_exit: 0) do
        command = Hive::Commands::Web.new
        system_calls = []
        command.define_singleton_method(:system) do |*argv|
          system_calls << argv
          true
        end

        replacement = ->(env, *argv) { raise ExecCaught.new(env, argv) }
        with_replaced_singleton_method(Kernel, :exec, replacement) do
          with_env("HIVEBOX_PRECOMPILED_ASSETS" => "1") do
            assert_raises(ExecCaught) { capture_io { command.call } }
          end
        end

        assert_equal [ %w[bin/rails db:prepare] ], system_calls.map { |call| call.last(2) },
                     "Hivebox should use the asset graph validated while its image is built"
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
        File.write(File.join(app_dir, "bin", "rails"), <<~SH)
          #!/usr/bin/env bash
          if [ "$1" = "assets:precompile" ]; then
            mkdir -p public/assets
            printf 'body {}\n' > public/assets/application-test.css
            printf 'export {}\n' > public/assets/application-test.js
            printf '%s\n' '{"application.css":{"digested_path":"application-test.css"},"application.js":{"digested_path":"application-test.js"}}' > public/assets/.manifest.json
          fi
          exit 0
        SH
        FileUtils.chmod(0o755, File.join(app_dir, "bin", "rails"))

        original = Kernel.method(:exec)
        caught = nil
        Dir.chdir(parent) do
          with_env("HIVE_WEB_APP_DIR" => app_name) do
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
      assets = File.join(dir, "public", "assets")
      FileUtils.mkdir_p(assets)
      File.write(File.join(assets, "application.css"), "body {}")
      File.write(File.join(assets, "application.js"), "export {}")
      File.write(File.join(assets, ".manifest.json"), JSON.generate(
        "application.css" => { "digested_path" => "application.css" },
        "application.js" => { "digested_path" => "application.js" }
      ))
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin", "rails"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(dir, "bin", "rails"))
      assets = File.join(dir, "public", "assets")
      FileUtils.mkdir_p(assets)
      File.write(File.join(assets, "application-test.css"), "body {}\n")
      File.write(File.join(assets, "application-test.js"), "export {}\n")
      File.write(
        File.join(assets, ".manifest.json"),
        JSON.generate(
          "application.css" => { "digested_path" => "application-test.css" },
          "application.js" => { "digested_path" => "application-test.js" }
        )
      )

      command = Hive::Commands::Web.new
      system_calls = []
      command.define_singleton_method(:system) do |*argv|
        system_calls << argv
        true
      end
      replacement = ->(env, *argv) { raise ExecCaught.new(env, argv) }
      exact_rails = [
        "/exact/ruby", "/exact/bundle", "exec", "/exact/ruby",
        File.join(dir, "bin", "rails")
      ]
      rails_argv_calls = []
      caught = with_replaced_singleton_method(
        Hive::Web::AppBundle, :rails_argv, ->(actual_dir, *arguments) {
          rails_argv_calls << [ actual_dir, arguments ]
          exact_rails
        }
      ) do
        with_replaced_singleton_method(Kernel, :exec, replacement) do
          assert_raises(ExecCaught) { capture_io { command.call } }
        end
      end

      assert_equal Hive::Web::AppBundle.hive_cli_root, caught.env["HIVE_CLI_ROOT"]
      assert_equal Hive::Web::AppBundle.dependency_dir, caught.env["BUNDLE_PATH"]
      assert_equal [ [ dir, [] ] ], rails_argv_calls
      assert_equal [ [ *exact_rails, "db:prepare" ] ], system_calls.map { |call| call.drop(1) },
                   "managed database preparation must run through the locked Bundler"
      assert_equal [ *exact_rails, "server", "-b", "127.0.0.1", "-p", "4567" ], caught.argv,
                   "managed Rails server must run through the locked Bundler"
    end
  end

  # ── `hive web install` orchestration ────────────────────────────────
  # install_service maps the installer outcome onto the CLI error contract:
  # a drifted unit → InvalidTaskPath (retry with --force), a failed install →
  # Hive::Error, and --json emits the hive-web-install envelope. Swap in a fake
  # installer so the mapping is asserted without touching launchctl/systemctl.
  def with_fake_web_installer(outcome_kind, state: nil, install_error: nil,
                              outcome_restarted: false, restart_calls: nil)
    require "hive/commands/web/service_installer"
    require "hive/commands/service_installer/outcome"
    outcome = Hive::Commands::ServiceInstaller::Outcome.new(
      outcome_kind,
      restarted: outcome_restarted
    )
    service_state = state || {
      "platform" => "macos", "unit_path" => "/tmp/local.hive-web.plist",
      "service_installed" => true, "service_enabled" => true,
      "service_running" => true, "service_manager_available" => true,
      "url" => "http://127.0.0.1:4567", "ready" => true, "readiness" => "ready"
    }
    fake = Class.new do
      define_method(:initialize) { |**_kwargs| }
      define_method(:install!) do |autostart:, force:|
        raise install_error if install_error

        outcome
      end
      define_method(:service_lifecycle_state) { service_state }
      define_method(:restart!) do
        restart_calls << true if restart_calls
        true
      end
      define_method(:messages) { [ "installed note" ] }
      define_method(:target_path) { "/tmp/local.hive-web.plist" }
      define_method(:envelope_platform) { "macos" }
    end
    original = Hive::Commands::Web.const_get(:ServiceInstaller)
    Hive::Commands::Web.send(:remove_const, :ServiceInstaller)
    Hive::Commands::Web.const_set(:ServiceInstaller, fake)
    begin
      with_replaced_singleton_method(Hive::Web::ServiceStatus, :snapshot, ->(**) { service_state }) do
        yield
      end
    ensure
      Hive::Commands::Web.send(:remove_const, :ServiceInstaller)
      Hive::Commands::Web.const_set(:ServiceInstaller, original)
    end
  end

  def test_install_envelope_allows_a_cold_rails_boot_readiness_window
    installer = Struct.new(:target_path, :messages).new("/tmp/hive-web.service", [])
    outcome = Hive::Commands::ServiceInstaller::Outcome.new(:written)
    observed = nil
    state = {
      "platform" => "linux", "unit_path" => installer.target_path,
      "service_installed" => true, "service_enabled" => true,
      "service_running" => true, "service_manager_available" => true,
      "url" => "http://127.0.0.1:4567", "ready" => true, "readiness" => "ready"
    }

    with_replaced_singleton_method(Hive::Web::ServiceStatus, :snapshot, lambda { |**kwargs|
      observed = kwargs
      state
    }) do
      envelope = Hive::Commands::Web.new.send(
        :service_envelope, installer, outcome,
        config: Hive::Config::DEFAULTS.fetch("web")
      )

      assert envelope["ok"]
    end

    assert_equal true, observed.fetch(:wait_for_running)
    assert_equal Hive::Commands::Web::INSTALL_READINESS_ATTEMPTS, observed.fetch(:attempts)
    assert_equal Hive::Commands::Web::INSTALL_READINESS_INTERVAL_SEC, observed.fetch(:interval)
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

  def test_force_install_forces_managed_bundle_refresh
    observed = nil
    restart_calls = []
    replacement = lambda do |**kwargs|
      observed = kwargs
      Hive::Web::AppBundle.app_dir
    end

    with_tmp_global_config do
      with_fake_web_installer(:unchanged, restart_calls: restart_calls) do
        with_replaced_singleton_method(Hive::Web::AppBundle, :ensure!, replacement) do
          out, = capture_io { Hive::Commands::Web.new("install", force: true, json: true).call }
          assert_equal true, JSON.parse(out).fetch("restarted")
        end
      end
    end

    assert_equal true, observed.fetch(:force_refresh)
    assert_equal [ true ], restart_calls
  end

  def test_force_install_does_not_restart_twice_after_unit_upgrade_restart
    restart_calls = []

    with_tmp_global_config do
      with_fake_web_installer(
        :upgraded,
        outcome_restarted: true,
        restart_calls: restart_calls
      ) do
        with_replaced_singleton_method(
          Hive::Web::AppBundle,
          :ensure!,
          ->(**) { Hive::Web::AppBundle.app_dir }
        ) do
          out, = capture_io { Hive::Commands::Web.new("install", force: true, json: true).call }
          assert_equal true, JSON.parse(out).fetch("restarted")
        end
      end
    end

    assert_empty restart_calls
  end

  def test_install_service_json_envelope_shape
    with_tmp_global_config do
      with_fake_web_installer(:written) do
        out, = capture_io { Hive::Commands::Web.new("install", no_bootstrap: true, json: true).call }
        payload = JSON.parse(out)
        assert_equal "hive-web-install", payload["schema"]
        assert_equal 1, payload["schema_version"]
        assert_equal true, payload["ok"]
        assert_equal "managed_service", payload["mode"]
        assert_equal "written", payload["outcome"]
        assert_equal "macos", payload["platform"]
        assert_equal "/tmp/local.hive-web.plist", payload["target_path"]
        assert payload.key?("backup_path"), "envelope must carry backup_path"
        assert payload.key?("restarted"), "envelope must carry restarted"
        assert_kind_of Array, payload["messages"]
      end
    end
  end

  def test_install_service_json_fails_when_service_does_not_become_ready
    state = {
      "platform" => "macos", "unit_path" => "/tmp/local.hive-web.plist",
      "service_installed" => true, "service_enabled" => true,
      "service_running" => false, "service_manager_available" => true,
      "url" => "http://127.0.0.1:4567", "ready" => false, "readiness" => "inactive"
    }

    with_tmp_global_config do
      with_fake_web_installer(:written, state: state) do
        output = StringIO.new
        original_stdout = $stdout
        begin
          $stdout = output
          error = assert_raises(Hive::Error) do
            Hive::Commands::Web.new("install", no_bootstrap: true, json: true).call
          end
          assert_match(/did not become ready/, error.message)
        ensure
          $stdout = original_stdout
        end

        payload = JSON.parse(output.string)
        assert_equal false, payload["ok"]
        assert_equal "inactive", payload["readiness"]
      end
    end
  end

  def test_install_bootstrap_failure_emits_versioned_json_error
    context = {
      "mode" => "managed_service", "warnings" => [], "platform" => "linux",
      "unit_path" => "/tmp/hive-web.service", "service_installed" => true,
      "service_enabled" => true, "service_running" => false,
      "service_manager_available" => true, "url" => "http://127.0.0.1:4567",
      "ready" => false, "readiness" => "inactive"
    }
    output = StringIO.new
    original_stdout = $stdout
    error = nil
    begin
      $stdout = output
      error = assert_raises(Hive::Error) do
        with_replaced_singleton_method(Hive::Web::AppBundle, :ensure!, ->(*) { raise Hive::Error, "download failed" }) do
          with_replaced_singleton_method(Hive::Commands::Web, :error_context, ->(**) { context }) do
            Hive::Commands::Web.new("install", json: true).call
          end
        end
      end
    ensure
      $stdout = original_stdout
    end

    assert_match(/download failed/, error.message)
    payload = JSON.parse(output.string)
    assert_equal "hive-web-install", payload["schema"]
    assert_equal 1, payload["schema_version"]
    assert_equal false, payload["ok"]
    assert_equal "bootstrap_failed", payload["error_kind"]
    assert_equal "managed_service", payload["mode"]
    assert_equal "inactive", payload["readiness"]
  end

  def test_install_service_exception_emits_one_versioned_json_error
    with_tmp_global_config do
      with_fake_web_installer(
        :written,
        install_error: Hive::Error.new("service manager exploded")
      ) do
        out, = capture_io do
          error = assert_raises(Hive::Error) do
            Hive::Commands::Web.new("install", no_bootstrap: true, json: true).call
          end
          assert_match(/service manager exploded/, error.message)
        end

        payload = JSON.parse(out)
        assert_equal "hive-web-install", payload["schema"]
        assert_equal false, payload["ok"]
        assert_equal "service_install_failed", payload["error_kind"]
        assert_equal 1, out.lines.length, "JSON mode must emit exactly one install document"
      end
    end
  end

  def test_install_json_and_stderr_include_legacy_alias_guidance_once
    with_tmp_global_config do
      with_fake_web_installer(:written) do
        error = StringIO.new
        environment = { "HIVEBOX_ORIGIN" => "https://legacy.example" }
        out, = capture_io do
          Hive::Commands::Web.new(
            "install",
            no_bootstrap: true,
            json: true,
            environment: environment,
            error: error
          ).call
        end
        payload = JSON.parse(out)

        assert_equal 1, payload.fetch("warnings").length
        assert_equal "HIVEBOX_ORIGIN", payload.dig("warnings", 0, "alias")
        assert_equal "HIVE_WEB_ORIGIN", payload.dig("warnings", 0, "replacement")
        assert_equal 1, error.string.scan("HIVEBOX_ORIGIN").length
      end
    end
  end

  # ── loopback no-auth env export matrix ──────────────────────────────
  # `call` sets HIVE_WEB_LOCAL_LOOPBACK=1 only when the bind is loopback AND
  # web.local_loopback is still true; the Rails side trusts that env var to
  # enable the no-auth bypass, so the CLI must export it exactly in that case.
  def captured_exec_env(bind:, unsafe: false, web_config: nil, environment: nil)
    caught = nil
    with_tmp_global_config do |dir|
      if web_config
        File.write(File.join(dir, "config.yml"),
                   { "registered_projects" => [], "web" => web_config }.to_yaml)
      end
      with_stub_rails_app(prepare_exit: 0) do
        app_dir = ENV.fetch("HIVE_WEB_APP_DIR")
        child_environment = environment&.merge("HIVE_WEB_APP_DIR" => app_dir) || ENV
        original = Kernel.method(:exec)
        Kernel.define_singleton_method(:exec) { |env, *argv| raise ExecCaught.new(env, argv) }
        begin
          capture_io do
            Hive::Commands::Web.new(
              bind: bind, unsafe: unsafe, environment: child_environment
            ).call
          end
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
    assert_equal "1", captured_exec_env(bind: "127.0.0.1")["HIVE_WEB_LOCAL_LOOPBACK"],
                 "a loopback bind with local_loopback enabled must signal the no-auth bypass"
  end

  def test_non_loopback_bind_clears_inherited_loopback_bypass
    env = captured_exec_env(
      bind: "0.0.0.0", unsafe: true,
      environment: { "HIVE_WEB_LOCAL_LOOPBACK" => "1" }
    )
    assert env.key?("HIVE_WEB_LOCAL_LOOPBACK")
    assert_nil env["HIVE_WEB_LOCAL_LOOPBACK"],
               "the exec environment must actively remove a parent's loopback bypass"
  end

  def test_legacy_timeout_aliases_reach_child_under_canonical_names
    env = captured_exec_env(
      bind: "127.0.0.1",
      environment: {
        "HIVEBOX_DIFF_TIMEOUT_SEC" => "41",
        "HIVEBOX_CLONE_TIMEOUT_SEC" => "242"
      }
    )

    assert_equal "41", env["HIVE_WEB_DIFF_TIMEOUT_SEC"]
    assert_equal "242", env["HIVE_WEB_CLONE_TIMEOUT_SEC"]
    assert_nil env["HIVEBOX_DIFF_TIMEOUT_SEC"]
    assert_nil env["HIVEBOX_CLONE_TIMEOUT_SEC"]
  end

  def test_loopback_env_omitted_when_config_opts_out
    env = captured_exec_env(bind: "127.0.0.1", web_config: { "local_loopback" => false })
    assert env.key?("HIVE_WEB_LOCAL_LOOPBACK")
    assert_nil env["HIVE_WEB_LOCAL_LOOPBACK"],
               "web.local_loopback:false must clear the bypass even on a loopback bind"
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
    state = {
      "service_installed" => true, "service_enabled" => false,
      "service_running" => false, "service_manager_available" => true
    }
    out, = with_fake_service_installer(platform: "linux", state: state) do
      capture_io { command.call }
    end
    assert_match(/manager_available=true installed=true enabled=false running=false ready=false/, out)
    assert_match(/readiness=disabled/, out)
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
    assert_equal "managed_service", payload["mode"]
    assert_equal true, payload["service_installed"], "the installer's service_state must be merged into the envelope"
    assert_equal false, payload["service_running"]
    assert_equal false, payload["ready"]
    assert_equal "disabled", payload["readiness"]
  end

  def test_status_service_json_emits_versioned_error_when_config_is_invalid
    command = Hive::Commands::Web.new("status", json: true)
    output = StringIO.new
    original_stdout = $stdout
    begin
      $stdout = output
      error = assert_raises(Hive::ConfigError) do
        with_replaced_singleton_method(
          Hive::Config,
          :load_global_web,
          -> { raise Hive::ConfigError, "invalid web config" }
        ) { command.call }
      end
      assert_equal Hive::ExitCodes::CONFIG, error.exit_code
    ensure
      $stdout = original_stdout
    end

    payload = JSON.parse(output.string)
    assert_equal "hive-web-status", payload["schema"]
    assert_equal 1, payload["schema_version"]
    assert_equal false, payload["ok"]
    assert_equal "config_error", payload["error_kind"]
    assert_equal Hive::ExitCodes::CONFIG, payload["exit_code"]
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
