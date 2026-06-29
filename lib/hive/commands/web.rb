require "fileutils"
require "json"
require "hive/config"
require "hive/paths"
require "hive/web/session_secret"
require "hive/web/app_bundle"

module Hive
  module Commands
    class Web
      VALID_SUBCOMMANDS = %w[install start stop status].freeze

      def initialize(subcommand = nil, bind: nil, port: nil, no_bootstrap: false,
                     unsafe: false, force: false, json: false, detach: false)
        @subcommand = subcommand
        @bind = bind
        @port = port
        @no_bootstrap = no_bootstrap
        @unsafe = unsafe
        @force = force
        @json = json
        @detach = detach
      end

      def call
        return service_command if @subcommand

        cfg = Hive::Config.load_global_web
        bind = @bind || cfg.fetch("bind")
        port = (@port || cfg.fetch("port")).to_i
        enforce_bind_policy!(bind, cfg)
        app_dir = rails_app_dir(bootstrap: !@no_bootstrap)
        unless app_dir
          warn "hive web: the hivebox web app (web/) was not found. " \
               "Run `hive web install`, or point HIVEBOX_WEB_APP_DIR at the Rails app."
          exit 1
        end

        env = {
          "RAILS_ENV" => ENV.fetch("RAILS_ENV", "production"),
          # Rails' secret_key_base derives from the same persisted secret the
          # session cookies used pre-Rails, so recreating the container keeps
          # sessions (the file lives on the /data mount).
          "SECRET_KEY_BASE" => ENV["SECRET_KEY_BASE"] ||
            Hive::Web::SessionSecret.load_or_create(cfg.fetch("session_secret_file")),
          "HIVEBOX_ORIGIN" => cfg.fetch("origin"),
          # The solid_cable/cache/queue sqlite files must survive image
          # upgrades — keep them in state_home (on /data in the container),
          # not in the app dir.
          "HIVEBOX_STORAGE_DIR" => ENV["HIVEBOX_STORAGE_DIR"] ||
            File.join(Hive::Paths.state_home, "web-storage"),
          "BUNDLE_GEMFILE" => File.join(app_dir, "Gemfile")
        }
        env["HIVEBOX_LOCAL_LOOPBACK"] = "1" if loopback_bind?(bind)
        FileUtils.mkdir_p(env.fetch("HIVEBOX_STORAGE_DIR"))

        Dir.chdir(app_dir) do
          # Idempotent: creates/migrates the solid-stack sqlite databases on
          # first boot, no-ops afterwards. Array form — no shell involved.
          # Typed error so a persistent failure surfaces as guidance, not a
          # raw backtrace looping every 5s under the container supervisor.
          unless system(env, "bin/rails", "db:prepare")
            raise Hive::Error,
                  "hive web: db:prepare failed — check that " \
                  "#{env.fetch("HIVEBOX_STORAGE_DIR")} is writable (the /data mount) " \
                  "and that the web bundle is installed (cd #{app_dir} && bundle install)"
          end
          puts "hive web: listening on http://#{bind}:#{port}"
          # Replace this process with the Rails server (array form, env hash;
          # Kernel#exec never touches a shell when given an argv list).
          Kernel.exec env, "bin/rails", "server", "-b", bind, "-p", port.to_s
        end
      end

      private

      def service_command
        require "hive/commands/web/service_installer"
        case @subcommand
        when "install"
          Hive::Web::AppBundle.ensure! unless @no_bootstrap
          install_service
        when "start"
          if @detach
            start_service
          else
            @subcommand = nil
            call
          end
        when "stop" then stop_service
        when "status" then status_service
        else
          raise Hive::InvalidTaskPath,
                "hive web: unknown subcommand #{@subcommand.inspect} (expected: #{VALID_SUBCOMMANDS.join(', ')})"
        end
      end

      def rails_app_dir(bootstrap: true)
        candidates = [
          ENV["HIVEBOX_WEB_APP_DIR"],
          Hive::Paths.web_app_home,
          File.expand_path("../../../web", __dir__)
        ].compact
        found = candidates.find { |dir| File.file?(File.join(dir, "config", "application.rb")) }
        return found if found
        return nil unless bootstrap

        Hive::Web::AppBundle.ensure!
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
        return if @unsafe
        return if cfg.dig("github", "owner").to_s != ""

        raise Hive::InvalidTaskPath,
              "hive web: refusing to bind #{bind} without web.github.owner. " \
              "Set an owner or pass --unsafe/--allow-public to keep the GitHub owner gate."
      end

      def loopback_bind?(bind)
        value = bind.to_s.downcase
        return true if value == "localhost" || value == "::1"
        return false unless value.match?(/\A\d+\.\d+\.\d+\.\d+\z/)

        value.split(".").first == "127"
      end

      def install_service
        installer = Hive::Commands::Web::ServiceInstaller.new
        outcome = installer.install!(autostart: true, force: @force)
        if @json
          puts JSON.generate(service_envelope(installer, outcome))
        else
          installer.messages.each { |line| warn "hive: #{line}" }
          puts "hive web: #{outcome.wire_outcome} #{installer.target_path}"
        end
        raise Hive::Error, "web service install failed" if outcome.failed?
        raise Hive::InvalidTaskPath, "web service differs; retry with --force" if outcome.drifted?
      end

      def start_service
        installer = Hive::Commands::Web::ServiceInstaller.new
        argv =
          if installer.envelope_platform == "macos"
            [ "launchctl", "load", installer.target_path ]
          else
            [ "systemctl", "--user", "start", installer.service_name ]
          end
        ok = system(*argv)
        raise Hive::Error, "hive web: could not start managed service" unless ok
      end

      def stop_service
        installer = Hive::Commands::Web::ServiceInstaller.new
        argv =
          if installer.envelope_platform == "macos"
            [ "launchctl", "unload", installer.target_path ]
          else
            [ "systemctl", "--user", "stop", installer.service_name ]
          end
        ok = system(*argv)
        raise Hive::Error, "hive web: could not stop managed service" unless ok
      end

      def status_service
        installer = Hive::Commands::Web::ServiceInstaller.new
        state = installer.service_state
        if @json
          puts JSON.generate({ "schema" => "hive-web-status", "ok" => true }.merge(state))
        else
          puts "hive web: service #{state["service_installed"] ? "installed" : "not installed"}"
        end
      end

      def service_envelope(installer, outcome)
        {
          "schema" => "hive-web-install",
          "ok" => outcome.success?,
          "outcome" => outcome.wire_outcome,
          "platform" => installer.envelope_platform,
          "target_path" => installer.target_path,
          "backup_path" => outcome.backup_path,
          "restarted" => outcome.restarted,
          "messages" => installer.messages.dup
        }
      end
    end
  end
end
