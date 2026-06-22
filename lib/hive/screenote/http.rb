require "json"
require "net/http"
require "openssl"
require "uri"
require "hive"

module Hive
  module Screenote
    # Shared HTTP transport defaults for the Screenote OAuth and MCP
    # clients. Lives in one module so a timeout change (or a new retryable
    # error class) lands in BOTH clients at once. Previously McpClient
    # reached into OAuthClient's constants, so the two were coupled through
    # one class's private surface — changing OAuthClient's timeout silently
    # rebound McpClient.
    module Http
      OPEN_TIMEOUT_SEC = 5
      READ_TIMEOUT_SEC = 10
      # Transport failures mapped to a friendly Hive::Error ("could not
      # reach Screenote") instead of an opaque crash. SystemCallError is the
      # Errno::* superclass — it covers ECONNREFUSED/ECONNRESET/EHOSTUNREACH
      # plus ETIMEDOUT/ENETUNREACH/EPIPE, which OS-level TCP failures raise.
      # OpenSSL::SSL::SSLError covers TLS/cert failures on the https
      # endpoints (Screenote is the first user-configured external HTTPS
      # service, so these became reachable). SocketError and IOError are not
      # SystemCallError subclasses, so they stay listed explicitly.
      NETWORK_ERRORS = [
        Net::OpenTimeout, Net::ReadTimeout, SocketError,
        OpenSSL::SSL::SSLError, SystemCallError, IOError
      ].freeze

      module_function

      def options(uri)
        { use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT_SEC, read_timeout: READ_TIMEOUT_SEC }
      end

      # Run `request` against `uri`'s host/port using `http` (Net::HTTP or a
      # test double), raising a typed Hive::Error on a non-2xx response or a
      # mapped transport failure. `context` prefixes both messages.
      def request(http:, request:, uri:, context:)
        response = http.start(uri.host, uri.port, **options(uri)) { |conn| conn.request(request) }
        raise Hive::Error, "#{context} failed (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)

        response
      rescue *NETWORK_ERRORS => e
        raise Hive::Error, "#{context}: could not reach Screenote (#{e.class}: #{e.message})"
      end
    end
  end
end
