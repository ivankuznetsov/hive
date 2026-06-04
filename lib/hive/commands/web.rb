require "hive/config"
require "hive/web/app"

module Hive
  module Commands
    class Web
      def initialize(bind: nil, port: nil)
        @bind = bind
        @port = port
      end

      def call
        cfg = Hive::Config.load_global_web
        bind = @bind || cfg.fetch("bind")
        port = (@port || cfg.fetch("port")).to_i
        require "puma"
        require "rackup"

        app = Hive::Web::App
        server = Puma::Server.new(app)
        server.add_tcp_listener(bind, port)
        puts "hive web: listening on http://#{bind}:#{port}"
        server.run.join
      end
    end
  end
end
