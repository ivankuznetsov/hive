# frozen_string_literal: true

require "openssl"
require "socket"
require "json"

# A real TLS peer, including certificate and hostname verification. The handler
# sees the complete request before deciding whether to respond or disconnect.
class RemoteTlsServer
  attr_reader :url, :certificate_path, :requests

  def initialize(root:, &handler)
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=remote-test-#{key.object_id}")
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    extensions = OpenSSL::X509::ExtensionFactory.new
    extensions.subject_certificate = extensions.issuer_certificate = certificate
    certificate.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
    certificate.add_extension(extensions.create_extension("subjectAltName", "IP:127.0.0.1,DNS:localhost"))
    certificate.sign(key, OpenSSL::Digest::SHA256.new)
    @certificate_path = File.join(root, "remote-test-ca-#{key.object_id}.pem")
    File.write(@certificate_path, certificate.to_pem)
    context = OpenSSL::SSL::SSLContext.new
    context.cert, context.key = certificate, key
    @tcp = TCPServer.new("127.0.0.1", 0)
    @url = "https://127.0.0.1:#{@tcp.addr[1]}"
    @server = OpenSSL::SSL::SSLServer.new(@tcp, context)
    @requests = []
    @thread = Thread.new do
      loop do
        socket = @server.accept
        begin
          line = socket.gets
          next unless line

          method, path, = line.split
          headers = {}
          while (line = socket.gets) && line != "\r\n"
            name, value = line.split(":", 2)
            headers[name.downcase] = value.strip
          end
          body = socket.read(headers.fetch("content-length", "0").to_i)
          request = { method: method, path: path, headers: headers, body: body }
          @requests << request
          response = handler.call(request)
          next if response == :disconnect

          status, response_headers, bytes = response
          bytes = JSON.generate(bytes) unless bytes.is_a?(String)
          response_headers = { "Content-Type" => "application/json", "Content-Length" => bytes.bytesize.to_s,
                               "Connection" => "close" }.merge(response_headers || {}).compact
          socket.write("HTTP/1.1 #{status} Response\r\n")
          response_headers.each { |name, value| socket.write("#{name}: #{value}\r\n") }
          if response_headers["Transfer-Encoding"] == "chunked"
            socket.write("\r\n#{bytes.bytesize.to_s(16)}\r\n#{bytes}\r\n0\r\n\r\n")
          else
            socket.write("\r\n#{bytes}")
          end
        rescue Errno::EPIPE, Errno::ECONNRESET, OpenSSL::SSL::SSLError, IOError
          # Rejected certificates and deliberately timed-out clients are normal.
        ensure
          socket.close
        end
      rescue OpenSSL::SSL::SSLError
        retry
      end
    end
    @thread.report_on_exception = false
  end

  def close
    @thread.kill
    @tcp.close
    @thread.join
  end

  def self.envelope(data, instance: "server-1", **extra)
    { "schema" => "hive-remote", "schema_version" => 1, "ok" => true,
      "instance_id" => instance, "data" => data }.merge(extra.transform_keys(&:to_s))
  end

  def self.metadata(scopes: %w[read create act answer], instance: "server-1", version: "v1")
    { "instance_id" => instance, "api_version" => version,
      "token" => { "id" => "public-1", "scopes" => scopes, "projects" => [ "demo" ],
                   "all_projects" => false, "expires_at" => nil } }
  end
end
