require "securerandom"
require "socket"
require "uri"

module Hive
  module Artifacts
    # Controller-owned HTTP proxy for browser evidence. The browser sees one
    # random .invalid origin; every request is mapped to one controller-chosen
    # loopback application port. This keeps agent-browser's hostname allowlist
    # useful without granting the producer access to every localhost service.
    class CaptureProxy
      MAX_HEADER_BYTES = 64 * 1024
      MAX_CONNECTIONS = 64
      READ_TIMEOUT_SECONDS = 5

      attr_reader :app_port, :origin, :proxy_url, :hostname

      class ProxyError < Hive::Error; end

      def initialize(app_port: nil)
        @hostname = "hive-capture-#{SecureRandom.hex(12)}.invalid"
        @app_port = app_port ? Integer(app_port) : reserve_port
        unless @app_port.between?(1, 65_535)
          raise ProxyError, "capture application port is invalid"
        end
        @server = TCPServer.new("127.0.0.1", 0)
        @server.listen(MAX_CONNECTIONS)
        @proxy_url = "http://127.0.0.1:#{@server.local_address.ip_port}"
        @origin = "http://#{hostname}"
        @clients = []
        @client_threads = []
        @mutex = Mutex.new
        @closed = false
        @accept_thread = Thread.new { accept_connections }
        @accept_thread.report_on_exception = false
      rescue ArgumentError, TypeError, SystemCallError => e
        close
        raise ProxyError, "capture origin proxy is unavailable: #{e.message}"
      end

      def close
        @mutex&.synchronize do
          @closed = true
          @server&.close unless @server&.closed?
          @clients&.each { |socket| socket.close unless socket.closed? }
        end
        @accept_thread&.join(1)
        @client_threads&.each { |thread| thread.join(1) }
        true
      rescue IOError, SystemCallError
        false
      end

      private

      def reserve_port
        socket = TCPServer.new("127.0.0.1", 0)
        socket.local_address.ip_port
      ensure
        socket&.close
      end

      def accept_connections
        loop do
          client = @server.accept
          stop = false
          @mutex.synchronize do
            if @closed
              client.close
              stop = true
            else
              @client_threads.reject! { |candidate| !candidate.alive? }
            end
            if !stop && @client_threads.length >= MAX_CONNECTIONS
              reject_busy(client)
            elsif !stop
              @clients << client
              thread = Thread.new { handle(client) }
              thread.report_on_exception = false
              @client_threads << thread
            end
          end
          break if stop
        end
      rescue IOError, Errno::EBADF
        nil
      rescue SystemCallError
        retry unless @closed
      end

      def handle(client)
        upstream = nil
        head, remainder = read_header(client)
        method, target, version = head.lines.first.to_s.strip.split(" ", 3)
        uri = URI.parse(target.to_s)
        return reject(client, "403 Forbidden") unless request_allowed?(method, uri, version)

        upstream = Socket.tcp("127.0.0.1", app_port, connect_timeout: READ_TIMEOUT_SECONDS)
        upstream.write(rewrite_request(head, method, uri, version))
        upstream.write(remainder) unless remainder.empty?
        relay_response(client, upstream)
      rescue URI::InvalidURIError, ProxyError
        reject(client, "400 Bad Request")
      rescue SystemCallError, IOError
        reject(client, "502 Bad Gateway")
      ensure
        upstream&.close unless upstream&.closed?
        @mutex.synchronize { @clients.delete(client) }
        client.close unless client.closed?
      end

      def read_header(client)
        bytes = +"".b
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READ_TIMEOUT_SECONDS
        until (index = bytes.index("\r\n\r\n"))
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise ProxyError, "capture proxy request timed out" unless remaining.positive?
          raise ProxyError, "capture proxy request header is oversized" if bytes.bytesize >= MAX_HEADER_BYTES
          next unless IO.select([ client ], nil, nil, remaining)

          chunk = client.read_nonblock([ 8192, MAX_HEADER_BYTES - bytes.bytesize ].min)
          bytes << chunk
        end
        boundary = index + 4
        [ bytes.byteslice(0, boundary), bytes.byteslice(boundary..) || +"".b ]
      rescue EOFError, IO::WaitReadable
        raise ProxyError, "capture proxy request is incomplete"
      end

      def request_allowed?(method, uri, version)
        !method.to_s.empty? && method != "CONNECT" &&
          version.to_s.match?(/\AHTTP\/1\.[01]\z/) &&
          uri.scheme == "http" && uri.host == hostname && uri.port == 80 &&
          uri.userinfo.nil?
      end

      def rewrite_request(head, method, uri, version)
        upgrade = websocket_upgrade?(head)
        headers = head.lines.drop(1).reject do |line|
          hop_header = line.match?(/\A(?:Host|Proxy-Connection):/i)
          hop_header ||= !upgrade && line.match?(/\A(?:Connection|Upgrade):/i)
          hop_header || line == "\r\n"
        end
        prefix = [
          "#{method} #{uri.request_uri} #{version}\r\n",
          "Host: 127.0.0.1:#{app_port}\r\n"
        ]
        prefix << "Connection: close\r\n" unless upgrade
        (prefix + headers + [ "\r\n" ]).join
      end

      # The upstream must see a loopback Host header so an arbitrary project
      # cannot escape its development host allowlist. Frameworks such as Rails
      # consequently emit absolute redirects back to that loopback host. The
      # browser is intentionally allowed to visit only the random issued
      # origin, so translate only that exact controller-owned endpoint at the
      # proxy boundary. Relative and foreign redirects pass through unchanged.
      def rewrite_response(head)
        head.each_line.map do |line|
          next line unless line.match?(/\ALocation:/i)

          name, value = line.split(":", 2)
          uri = URI.parse(value.to_s.strip)
          next line unless uri.scheme == "http" && uri.host == "127.0.0.1" &&
                           uri.port == app_port && uri.userinfo.nil?

          uri.host = hostname
          uri.port = 80
          "#{name}: #{uri}\r\n"
        rescue URI::InvalidURIError
          line
        end.join
      end

      def websocket_upgrade?(head)
        connection = nil
        upgrade = nil
        head.each_line do |line|
          name, value = line.split(":", 2)
          next unless value

          connection = value if name.casecmp?("Connection")
          upgrade = value if name.casecmp?("Upgrade")
        end
        upgrade.to_s.strip.casecmp?("websocket") &&
          connection.to_s.split(",").any? { |token| token.strip.casecmp?("upgrade") }
      end

      def relay_response(client, upstream)
        head, remainder = read_header(upstream)
        client.write(rewrite_response(head))
        client.write(remainder) unless remainder.empty?
        relay(client, upstream)
      end

      def relay(client, upstream)
        sockets = [ client, upstream ]
        loop do
          ready = IO.select(sockets)&.first
          break unless ready
          ready.each do |source|
            chunk = source.read_nonblock(16 * 1024, exception: false)
            return if chunk.nil?
            next if chunk == :wait_readable

            (source.equal?(client) ? upstream : client).write(chunk)
          end
        end
      end

      def reject_busy(client)
        reject(client, "503 Service Unavailable")
        client.close
      end

      def reject(client, status)
        client.write("HTTP/1.1 #{status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
