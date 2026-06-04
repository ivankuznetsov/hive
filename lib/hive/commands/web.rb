require "hive/config"
require "hive/web/app"

module Hive
  module Commands
    class Web
      def initialize(bind: nil, port: nil)
        @bind = bind
        @port = port
      end

      # Puma's default pool tops out around 5 threads. Each open SSE stream
      # (`/events`, task logs) pins one thread for its whole lifetime, so the
      # default pool starves the box after a few dashboard tabs. Give the
      # streams ample headroom; the SseLimiter caps total concurrent streams
      # below this so request-serving threads always remain.
      MAX_THREADS = 32

      def call
        cfg = Hive::Config.load_global_web
        bind = @bind || cfg.fetch("bind")
        port = (@port || cfg.fetch("port")).to_i
        require "puma"

        warn_on_public_bind(bind, cfg)

        app = Hive::Web::App
        server = Puma::Server.new(app, nil, { min_threads: 0, max_threads: MAX_THREADS })
        server.add_tcp_listener(bind, port)
        puts "hive web: listening on http://#{bind}:#{port}"
        server.run.join
      end

      private

      # The box disables Rack::Protection's Host-header check on the
      # assumption that a trusted reverse proxy validates Host. Binding a
      # public interface (0.0.0.0) without that proxy exposes the app to
      # DNS-rebinding / Host-injection — the single highest-impact
      # misconfiguration for this box — so make it loud at startup.
      def warn_on_public_bind(bind, cfg)
        return unless bind.to_s == "0.0.0.0"
        return if cfg["origin"].to_s.start_with?("https://")

        warn "hive web: WARNING binding 0.0.0.0 without an https origin — " \
             "ensure a trusted reverse proxy validates the Host header " \
             "(Rack::Protection host_authorization is disabled for this box)."
      end
    end
  end
end
