require "socket"
require "uri"
require "hive"

module Hive
  module Screenote
    class LoopbackServer
      DEFAULT_TIMEOUT_SEC = 300
      # Per-read deadline and header byte cap for the callback request.
      # IO.select only guards `accept`; without the deadline a stalled or
      # partial local request could keep `socket.gets` blocked indefinitely
      # (a local DoS of the connect flow). MAX_REQUEST_BYTES bounds BOTH the
      # cumulative header bytes AND each individual `socket.gets` read (it is
      # passed as the gets length limit), so no single unterminated line is
      # read wholesale into memory.
      READ_TIMEOUT_SEC = 5
      MAX_REQUEST_BYTES = 64 * 1024

      attr_reader :host, :port

      def initialize(host: "127.0.0.1", port: 0, timeout_sec: DEFAULT_TIMEOUT_SEC,
                     read_timeout_sec: READ_TIMEOUT_SEC)
        @host = host
        @server = TCPServer.new(host, port)
        @port = @server.addr.fetch(1)
        @timeout_sec = timeout_sec
        @read_timeout_sec = read_timeout_sec
      end

      def redirect_uri
        "http://#{host}:#{port}/callback"
      end

      def wait_for_callback(expected_state:)
        # A browser/OS prefetch of `/` or `/favicon.ico` (or an empty/EOF
        # first line) must NOT consume the one real redirect and surface as a
        # bogus "state mismatch". Keep accepting until a `/callback` request
        # arrives; non-callback requests get a 404 and the loop continues.
        loop do
          socket = accept_socket
          begin
            path, params = read_callback_request(socket)
            unless callback_path?(path)
              write_response(socket, not_found_page, status: "404 Not Found")
              next
            end
            # Decide success/failure BEFORE writing the page. Writing the
            # success page first (the old order) showed "Screenote connected"
            # in the browser on a state-mismatch / missing-code callback while
            # the CLI aborted.
            error = callback_error(params, expected_state)
            write_response(socket, error ? failure_page : success_page)
            raise Hive::Error, error if error

            return { "code" => params["code"], "state" => params["state"] }
          ensure
            socket&.close
          end
        end
      ensure
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

      def callback_error(params, expected_state)
        return "Screenote authorization failed: #{params["error_description"] || params["error"]}" if params["error"]
        return "Screenote OAuth callback state mismatch" unless params["state"] == expected_state
        return "Screenote OAuth callback did not include a code" if params["code"].to_s.empty?

        nil
      end

      # Returns [path, params] for the request. `path` lets the caller drop
      # non-`/callback` prefetches; `params` is the decoded query string.
      def read_callback_request(socket)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @read_timeout_sec
        request_line = read_line(socket, deadline).to_s
        bytes = request_line.bytesize
        while (line = read_line(socket, deadline))
          break if line == "\r\n" || line == "\n"

          bytes += line.bytesize
          if bytes > MAX_REQUEST_BYTES
            raise Hive::Error, "Screenote OAuth callback request headers exceeded #{MAX_REQUEST_BYTES} bytes"
          end
        end
        path = request_line.split.fetch(1, "/")
        uri = URI("http://#{host}#{path}")
        [ uri.path, URI.decode_www_form(uri.query.to_s).to_h ]
      rescue URI::Error, ArgumentError
        # A junk local request (browser/OS prefetch, a port scanner) may carry
        # an invalid percent-escape (`/x%ZZ`) or an illegal character in the
        # request target. `URI(...)` / `URI.decode_www_form` raise
        # URI::InvalidURIError / ArgumentError, NEITHER of which is a
        # Hive::Error or SystemCallError — so it would escape Connect#call's
        # rescues and bin/hive as a raw backtrace (no --json envelope),
        # defeating the deliberate "tolerate junk local requests" design.
        # Treat it as a non-`/callback` request: the caller answers 404 and
        # keeps waiting for the real redirect.
        [ "/", {} ]
      end

      def callback_path?(path)
        path == "/callback"
      end

      # Read one line with a deadline so a stalled local client cannot block
      # the connect flow forever. The MAX_REQUEST_BYTES gets-limit caps a
      # single unterminated line so it cannot be slurped wholesale into
      # memory. Returns nil at EOF (caller ends its loop).
      def read_line(socket, deadline)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Hive::Error, "timed out reading Screenote OAuth callback request" if remaining <= 0

        ready = IO.select([ socket ], nil, nil, remaining)
        raise Hive::Error, "timed out reading Screenote OAuth callback request" unless ready

        socket.gets("\n", MAX_REQUEST_BYTES)
      end

      def write_response(socket, body, status: "200 OK")
        payload = "HTTP/1.1 #{status}\r\nContent-Type: text/html; charset=utf-8\r\n" \
                  "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
        socket.write(payload)
      rescue SystemCallError, IOError => e
        # The browser may have already closed the tab (EPIPE/ECONNRESET); the
        # page write is cosmetic, so swallow it. Crucially this must not
        # pre-empt the pending `raise Hive::Error, error` in wait_for_callback,
        # which carries the REAL reason (state mismatch / missing code).
        warn "[hive] could not write Screenote loopback response page: #{e.message}"
      end

      def success_page
        "<!doctype html><title>Screenote connected</title><p>You can close this tab.</p>"
      end

      def failure_page
        "<!doctype html><title>Screenote connection failed</title><p>Return to the terminal.</p>"
      end

      def not_found_page
        "<!doctype html><title>Screenote</title><p>Waiting for the Screenote authorization redirect.</p>"
      end
    end
  end
end
