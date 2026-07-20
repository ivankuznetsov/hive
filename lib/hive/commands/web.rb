require "fileutils"
require "json"
require "hive/config"
require "hive/paths"
require "hive/web/session_secret"
require "hive/web/app_bundle"
require "hive/web/environment"
require "hive/web/loopback"
require "hive/web/service_status"
require "hive/invoked_binary"

module Hive
  module Commands
    class Web
      def self.error_context(environment: ENV)
        require "hive/commands/web/service_installer"
        config = Hive::Config.load_global_web
        installer = ServiceInstaller.new(environment: environment, config: config)
        state = Hive::Web::ServiceStatus.snapshot(
          installer: installer, config: config, environment: environment
        )
        {
          "mode" => "managed_service",
          "warnings" => Hive::Web::Environment.warnings(environment: environment)
        }.merge(state)
      rescue StandardError
        config = Hive::Config::DEFAULTS.fetch("web")
        {
          "mode" => "managed_service",
          "warnings" => Hive::Web::Environment.warnings(environment: environment),
          "platform" => "unsupported",
          "unit_path" => nil,
          "service_installed" => false,
          "service_enabled" => false,
          "service_running" => false,
          "service_manager_available" => false,
          "url" => Hive::Web::ServiceStatus.effective_url(config, environment: environment),
          "ready" => false,
          "readiness" => "manager_unavailable"
        }
      end

      VALID_SUBCOMMANDS = %w[install start stop status].freeze

      def initialize(subcommand = nil, bind: nil, port: nil, no_bootstrap: false,
                     unsafe: false, force: false, json: false, detach: false,
                     environment: ENV, error: nil)
        @subcommand = subcommand
        @bind = bind
        @port = port
        @no_bootstrap = no_bootstrap
        @unsafe = unsafe
        @force = force
        @json = json
        @detach = detach
        @environment = environment
        @error = error
      end

      # Bare `hive web` (and `start` without --detach) runs the Rails server
      # in the foreground; install/start/stop/status manage the per-user
      # systemd/launchd service.
      def call
        Hive::Web::Environment.emit_warnings(
          environment: @environment,
          output: @error || $stderr,
          prefix: "hive web"
        )
        case @subcommand
        when nil then run_foreground
        when "install" then install_command
        when "start" then @detach ? start_service : run_foreground
        when "stop" then stop_service
        when "status" then status_service
        else
          raise Hive::InvalidTaskPath,
                "hive web: unknown subcommand #{@subcommand.inspect} (expected: #{VALID_SUBCOMMANDS.join(', ')})"
        end
      end

      private

      def run_foreground
        cfg = Hive::Config.load_global_web
        bind = @bind || cfg.fetch("bind")
        port = (@port || cfg.fetch("port")).to_i
        enforce_bind_policy!(bind, cfg)
        app_dir = rails_app_dir(bootstrap: !@no_bootstrap)
        unless app_dir
          warn "hive web: the Hive web app (web/) was not found. " \
               "Run `hive web install`, or point HIVE_WEB_APP_DIR at the Rails app."
          exit 1
        end

        env = {
          "RAILS_ENV" => @environment.fetch("RAILS_ENV", "production"),
          # Rails' secret_key_base derives from the same persisted secret the
          # session cookies used pre-Rails, so restarting the web service keeps
          # sessions signed in (the secret file is persisted under state_home).
          "SECRET_KEY_BASE" => @environment["SECRET_KEY_BASE"] ||
            Hive::Web::SessionSecret.load_or_create(cfg.fetch("session_secret_file")),
          "HIVE_WEB_ORIGIN" => Hive::Web::Environment.value(
            "HIVE_WEB_ORIGIN", environment: @environment, default: cfg.fetch("origin")
          ),
          # The solid_cable/cache/queue sqlite files must survive upgrades —
          # keep them under state_home, not in the app dir (the managed web
          # bundle is replaced wholesale on a version upgrade).
          "HIVE_WEB_STORAGE_DIR" => Hive::Web::Environment.value(
            "HIVE_WEB_STORAGE_DIR", environment: @environment
          ),
          "HIVE_WEB_DIFF_TIMEOUT_SEC" => Hive::Web::Environment.value(
            "HIVE_WEB_DIFF_TIMEOUT_SEC", environment: @environment
          ).to_s,
          "HIVE_WEB_CLONE_TIMEOUT_SEC" => Hive::Web::Environment.value(
            "HIVE_WEB_CLONE_TIMEOUT_SEC", environment: @environment
          ).to_s,
          "BUNDLE_GEMFILE" => File.join(app_dir, "Gemfile")
        }
        # Only the MANAGED bundle resolves the hive-cli path gem via
        # HIVE_CLI_ROOT — its ".." holds no gem, and its bundle was installed
        # with this same export. A source checkout or a HIVE_WEB_APP_DIR
        # override (e.g. the Hivebox image's baked /app/web) was
        # bundle-installed against its own ".."; re-pointing the path source
        # at runtime invalidates that prebuilt bundle (the v0.3.4/v0.3.5
        # image-smoke db:prepare failure).
        if app_dir == Hive::Web::AppBundle.app_dir
          env["HIVE_CLI_ROOT"] = Hive::Web::AppBundle.hive_cli_root
          env["BUNDLE_PATH"] = Hive::Web::AppBundle.dependency_dir
        end
        # The loopback no-auth bypass is opt-out: an operator can set
        # web.local_loopback: false to force GitHub login even on a loopback
        # bind. Only signal the bypass when both the bind is loopback AND the
        # config still allows it.
        local_loopback = Hive::Web::Environment.boolean(
          "HIVE_WEB_LOCAL_LOOPBACK",
          environment: @environment,
          default: cfg.fetch("local_loopback", true)
        )
        env["HIVE_WEB_LOCAL_LOOPBACK"] = loopback_bind?(bind) && local_loopback ? "1" : nil
        # The child Rails process receives canonical names only. Removing a
        # supplied legacy alias prevents a second warning after the CLI has
        # already reported and translated it.
        Hive::Web::Environment.legacy_names.each do |legacy|
          env[legacy] = nil if @environment.key?(legacy)
        end
        FileUtils.mkdir_p(env.fetch("HIVE_WEB_STORAGE_DIR"))

        Dir.chdir(app_dir) do
          # Idempotent: creates/migrates the solid-stack sqlite databases on
          # first boot, no-ops afterwards. Array form — no shell involved.
          # Typed error so a persistent failure surfaces as guidance, not a
          # raw backtrace looping on every restart under the service manager.
          unless system(env, "bin/rails", "db:prepare")
            raise Hive::Error,
                  "hive web: db:prepare failed — check that " \
                  "#{env.fetch("HIVE_WEB_STORAGE_DIR")} is writable " \
                  "and that the web bundle is installed (cd #{app_dir} && bundle install)"
          end
          puts "hive web: listening on http://#{bind}:#{port}"
          # Replace this process with the Rails server (array form, env hash;
          # Kernel#exec never touches a shell when given an argv list).
          Kernel.exec env, "bin/rails", "server", "-b", bind, "-p", port.to_s
        end
      end

      def install_command
        unless @no_bootstrap
          begin
            Hive::Web::AppBundle.ensure!
          rescue StandardError => e
            emit_install_error(e) if @json
            raise(e) if e.is_a?(Hive::Error)

            raise Hive::Error, "#{e.class}: #{e.message}"
          end
        end
        install_service
      end

      def rails_app_dir(bootstrap: true)
        # An explicit override is operator-managed, not the version-stamped
        # managed bundle — use it verbatim when it points at a real app.
        if (override = Hive::Web::Environment.value("HIVE_WEB_APP_DIR", environment: @environment))
          expanded = File.expand_path(override)
          unless File.file?(File.join(expanded, "config", "application.rb"))
            raise Hive::Error,
                  "HIVE_WEB_APP_DIR #{override.inspect} is not a Hive web Rails app " \
                  "(missing config/application.rb)"
          end
          return expanded
        end

        # The managed bundle takes precedence over a source checkout (matching
        # the original candidate order). Refresh it when present-but-stale (U2):
        # after a CLI upgrade the old Rails app is still on disk, so returning
        # it unconditionally would keep serving the pre-upgrade app. `ensure!`
        # re-provisions on missing OR stale and is a no-op when current.
        if Hive::Web::AppBundle.present?
          return bootstrap ? Hive::Web::AppBundle.ensure! : Hive::Web::AppBundle.app_dir
        end

        source = File.expand_path("../../../web", __dir__)
        return source if File.file?(File.join(source, "config", "application.rb"))

        bootstrap ? Hive::Web::AppBundle.ensure! : nil
      end

      # Rails' production host authorization is inactive by default — the box
      # assumes a trusted reverse proxy validates Host, exactly like the
      # pre-Rails posture. Binding a public interface without that proxy
      # exposes the app to DNS-rebinding / Host-injection, so make it loud.
      def warn_on_public_bind(bind, cfg)
        return unless bind.to_s == "0.0.0.0"
        return if cfg["origin"].to_s.start_with?("https://")

        warn "hive web: WARNING binding 0.0.0.0 without an https origin — " \
             "ensure a trusted reverse proxy validates the Host header."
      end

      def enforce_bind_policy!(bind, cfg)
        return if loopback_bind?(bind)

        # Non-loopback bind. Allowed only with --unsafe or a configured owner
        # gate. In BOTH allowed paths re-issue the 0.0.0.0-without-https
        # DNS-rebinding warning — previously lost when an owner was configured.
        if @unsafe || cfg.dig("github", "owner").to_s != ""
          # Make the security decision explicit: a configured owner (set for
          # OAuth) doubles as the gate that authorizes a non-loopback bind, so
          # an operator who set it for login reasons has implicitly opted into
          # a public bind. Say so loudly rather than only on the 0.0.0.0 path.
          unless @unsafe
            warn "hive web: binding non-loopback #{bind} — the GitHub owner gate " \
                 "(web.github.owner) is the only thing requiring login. Pass --unsafe " \
                 "to bind without an owner gate."
          end
          warn_on_public_bind(bind, cfg)
          return
        end

        raise Hive::InvalidTaskPath,
              "hive web: refusing to bind #{bind} without web.github.owner. " \
              "Set an owner or pass --unsafe/--allow-public to keep the GitHub owner gate."
      end

      def loopback_bind?(bind)
        Hive::Web::Loopback.address?(bind)
      end

      def install_service
        require "hive/commands/web/service_installer"
        config = Hive::Config.load_global_web
        installer = Hive::Commands::Web::ServiceInstaller.new(
          binary_path: Hive::InvokedBinary.path,
          environment: @environment,
          config: config
        )
        outcome = installer.install!(autostart: true, force: @force)
        envelope = service_envelope(installer, outcome, config: config)
        if @json
          puts JSON.generate(envelope)
        else
          installer.messages.each { |line| warn "hive: #{line}" }
          puts "hive web: #{outcome.wire_outcome} #{installer.target_path}"
          render_service_state(envelope)
        end
        raise Hive::Error, "web service install failed" if outcome.failed?
        raise Hive::InvalidTaskPath, "web service differs; retry with --force" if outcome.drifted?
        unless envelope["ok"]
          raise Hive::Error,
                "web service install did not become ready (readiness=#{envelope['readiness']})"
        end
      end

      def start_service
        run_service_action(launchctl: "load", systemctl: "start", verb: "start")
      end

      def stop_service
        run_service_action(launchctl: "unload", systemctl: "stop", verb: "stop")
      end

      # start/stop differ only in the launchctl (load/unload) and systemctl
      # (start/stop) verbs, so the platform branch lives here once.
      def run_service_action(launchctl:, systemctl:, verb:)
        require "hive/commands/web/service_installer"
        installer = Hive::Commands::Web::ServiceInstaller.new
        argv =
          if installer.envelope_platform == "macos"
            [ "launchctl", launchctl, installer.target_path ]
          else
            # A unit written while systemd-user was unavailable stays invisible
            # until a daemon-reload, so `start` would fail with "unit not found".
            # Reload before starting so a freshly written unit is picked up.
            system("systemctl", "--user", "daemon-reload") if verb == "start"
            [ "systemctl", "--user", systemctl, installer.service_name ]
          end
        ok = system(*argv)
        raise Hive::Error, "hive web: could not #{verb} managed service" unless ok
      end

      def status_service
        require "hive/commands/web/service_installer"
        begin
          config = Hive::Config.load_global_web
          installer = Hive::Commands::Web::ServiceInstaller.new(environment: @environment, config: config)
          state = Hive::Web::ServiceStatus.snapshot(
            installer: installer, config: config, environment: @environment
          )
        rescue StandardError => e
          emit_status_error(e) if @json
          raise
        end
        if @json
          puts JSON.generate({
            "schema" => "hive-web-status",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-web-status"),
            "ok" => true,
            "mode" => "managed_service",
            "warnings" => environment_warnings
          }.merge(state))
        else
          render_service_state(state)
        end
      end

      def service_envelope(installer, outcome, config: Hive::Config.load_global_web)
        state = Hive::Web::ServiceStatus.snapshot(
          installer: installer, config: config, environment: @environment,
          wait_for_running: true
        )
        {
          "schema" => "hive-web-install",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-web-install"),
          "ok" => outcome.success? && state["ready"],
          "mode" => "managed_service",
          "outcome" => outcome.wire_outcome,
          "platform" => installer.envelope_platform,
          "target_path" => installer.target_path,
          "backup_path" => outcome.backup_path,
          "restarted" => outcome.restarted,
          "messages" => installer.messages.dup,
          "warnings" => environment_warnings
        }.merge(state)
      end

      def emit_install_error(error)
        payload = Hive::Schemas::ErrorEnvelope.build(
          schema: "hive-web-install",
          error: error,
          error_kind: "bootstrap_failed",
          extras: self.class.error_context(environment: @environment)
        )
        puts JSON.generate(payload)
      end

      def emit_status_error(error)
        error_kind = error.is_a?(Hive::ConfigError) ? "config_error" : "status_failed"
        payload = Hive::Schemas::ErrorEnvelope.build(
          schema: "hive-web-status",
          error: error,
          error_kind: error_kind,
          extras: self.class.error_context(environment: @environment)
        )
        puts JSON.generate(payload)
      end

      def render_service_state(state)
        puts "hive web: service " \
             "manager_available=#{state["service_manager_available"]} " \
             "installed=#{state["service_installed"]} " \
             "enabled=#{state["service_enabled"]} " \
             "running=#{state["service_running"]} " \
             "ready=#{state["ready"]} " \
             "readiness=#{state["readiness"]}"
        puts "hive web: #{state["ready"] ? "ready at" : "configured at"} #{state["url"]}"
      end

      def environment_warnings
        @environment_warnings ||= Hive::Web::Environment.warnings(environment: @environment)
      end
    end
  end
end
