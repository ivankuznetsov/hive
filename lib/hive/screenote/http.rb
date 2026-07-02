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
      # service, so these became reachable). Net::WriteTimeout is a
      # Timeout::Error < RuntimeError (NOT a SystemCallError) and write_timeout
      # is left at Net::HTTP's 60s default, so a stalled POST-body write would
      # otherwise escape as an unmapped RuntimeError backtrace. SocketError and
      # IOError are not SystemCallError subclasses, so they stay listed
      # explicitly.
      NETWORK_ERRORS = [
        Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError,
        OpenSSL::SSL::SSLError, SystemCallError, IOError
      ].freeze

      module_function

      def options(uri)
        { use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT_SEC, read_timeout: READ_TIMEOUT_SEC }
      end

      # Parse `body` as a JSON object, raising a typed Hive::Error (prefixed
      # by `context`) when it is not valid JSON or not a JSON object. The
      # OAuth and MCP clients had near-identical copies of this — the exact
      # coupling Http was extracted to prevent — so it lives here once.
      # `empty_object:` keeps OAuth's empty-body→`{}` guard (some 200
      # responses legitimately carry no body); the MCP client leaves it off
      # so a blank body surfaces as the "unparseable" error it always was.
      def parse_json_object(body, context, empty_object: false)
        text = body.to_s.strip
        return {} if empty_object && text.empty?

        parsed = JSON.parse(text)
        return parsed if parsed.is_a?(Hash)

        raise Hive::Error, "#{context} returned a non-object response"
      rescue JSON::ParserError
        raise Hive::Error, "#{context} returned an unparseable response"
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
