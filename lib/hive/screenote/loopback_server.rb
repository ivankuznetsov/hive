require "socket"
require "uri"
require "hive"

module Hive
  module Screenote
    class LoopbackServer
      DEFAULT_TIMEOUT_SEC = 300

      attr_reader :host, :port

      def initialize(host: "127.0.0.1", port: 0, timeout_sec: DEFAULT_TIMEOUT_SEC)
        @host = host
        @server = TCPServer.new(host, port)
        @port = @server.addr.fetch(1)
        @timeout_sec = timeout_sec
      end

      def redirect_uri
        "http://#{host}:#{port}/callback"
      end

      def wait_for_callback(expected_state:)
        socket = accept_socket
        params = read_callback_params(socket)
        write_response(socket, params["error"] ? failure_page : success_page)
        raise Hive::Error, "Screenote authorization failed: #{params["error_description"] || params["error"]}" if params["error"]
        raise Hive::Error, "Screenote OAuth callback state mismatch" unless params["state"] == expected_state
        raise Hive::Error, "Screenote OAuth callback did not include a code" if params["code"].to_s.empty?

        { "code" => params["code"], "state" => params["state"] }
      ensure
        socket&.close
        close
      end

      def close
        @server&.close unless @server&.closed?
      end

      private

      def accept_socket
        ready = IO.select([ @server ], nil, nil, @timeout_sec)
        raise Hive::Error, "timed out waiting for Screenote OAuth callback" unless ready

        @server.accept
      end

      def read_callback_params(socket)
        request_line = socket.gets.to_s
        while (line = socket.gets)
          break if line == "\r\n" || line == "\n"
        end
        path = request_line.split.fetch(1, "/")
        uri = URI("http://#{host}#{path}")
        URI.decode_www_form(uri.query.to_s).to_h
      end

      def write_response(socket, body)
        payload = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" \
                  "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
        socket.write(payload)
      end

      def success_page
        "<!doctype html><title>Screenote connected</title><p>You can close this tab.</p>"
      end

      def failure_page
        "<!doctype html><title>Screenote connection failed</title><p>Return to the terminal.</p>"
      end
    end
  end
end
