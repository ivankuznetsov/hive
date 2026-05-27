require "socket"
require "json"

module Hive
  module E2E
    # A throwaway localhost HTTP server that serves a controlled GitHub
    # `releases/latest` response, so a real `hive` process pointed at it via
    # `HIVE_RELEASES_API_URL` sees a deterministic `tag_name`. Hermetic by
    # construction (binds 127.0.0.1 on an ephemeral port; no network). Plain
    # `TCPServer` rather than WEBrick to avoid a bundled-gem dependency.
    class ReleasesStubServer
      attr_reader :url

      def initialize(tag:)
        @tag = tag.to_s
        @server = TCPServer.new("127.0.0.1", 0)
        port = @server.addr[1]
        @url = "http://127.0.0.1:#{port}/releases/latest"
        @running = true
        @thread = Thread.new { serve_loop }
      end

      def stop
        @running = false
        @server.close
        @thread&.join(2)
      end

      private

      def serve_loop
        while @running
          client =
            begin
              @server.accept
            rescue IOError, Errno::EBADF
              break # socket closed by #stop
            end
          respond(client)
        end
      end

      def respond(client)
        client.timeout = 2 # don't let a half-open client park the serve loop (IO#timeout, Ruby 3.2+)
        client.gets("\r\n\r\n") # consume request line + headers
        body = JSON.generate("tag_name" => @tag)
        client.write("HTTP/1.1 200 OK\r\n" \
                     "Content-Type: application/json\r\n" \
                     "Content-Length: #{body.bytesize}\r\n" \
                     "Connection: close\r\n\r\n#{body}")
      rescue StandardError
        nil # a dropped/!malformed client connection must not kill the loop
      ensure
        client&.close
      end
    end
  end
end
