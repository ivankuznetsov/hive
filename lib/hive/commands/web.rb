require "hive/config"
require "hive/web/session_secret"

module Hive
  module Commands
    # Boots the hivebox web UI — a Rails app living in web/ at the repo root
    # (shipped in the Docker image at /app/web). hive itself stays a plain
    # CLI gem; the web tier is only supported where the Rails app and its
    # bundle exist: the hivebox container or a source checkout.
    class Web
      def initialize(bind: nil, port: nil)
        @bind = bind
        @port = port
      end

      def call
        cfg = Hive::Config.load_global_web
        bind = @bind || cfg.fetch("bind")
        port = (@port || cfg.fetch("port")).to_i
        app_dir = rails_app_dir
        unless app_dir
          warn "hive web: the hivebox web app (web/) was not found. " \
               "Run from the hivebox Docker image or a source checkout, " \
               "or point HIVEBOX_WEB_APP_DIR at the Rails app."
          exit 1
        end

        warn_on_public_bind(bind, cfg)

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

      def rails_app_dir
        candidates = [
          ENV["HIVEBOX_WEB_APP_DIR"],
          File.expand_path("../../../web", __dir__)
        ].compact
        candidates.find { |dir| File.file?(File.join(dir, "config", "application.rb")) }
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
    end
  end
end
