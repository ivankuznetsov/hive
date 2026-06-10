require "json"
require "net/http"
require "uri"

module Hive
  module Web
    # GitHub OAuth **device flow** gate (RFC 8628). hivebox is a headless box
    # whose public origin is unknown at auth time (localhost today, a Hetzner
    # VPS behind a tunnel tomorrow), so the callback-based web flow is a poor
    # fit: it demands a per-operator OAuth app whose redirect URI exactly
    # matches `web.origin`, plus a client secret in the environment. Device
    # flow needs only a public client_id with "Device Flow" enabled — the
    # operator enters a short code at github.com/login/device from any
    # browser, the box polls for the grant, and no client secret exists at
    # all. This also matches the paste-a-code UX the agent OAuth relay
    # already uses (see Hive::Web::AgentsAuth).
    class GithubAuth
      DEVICE_CODE_URL = URI("https://github.com/login/device/code")
      TOKEN_URL = URI("https://github.com/login/oauth/access_token")
      USER_URL = URI("https://api.github.com/user")
      GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code".freeze

      # Bound both legs of every GitHub call. Net::HTTP defaults to a 60s read
      # timeout; on the box's small Puma pool a hung GitHub would pin a thread
      # for a full minute (or until the client gives up), so cap it tightly.
      OPEN_TIMEOUT_SEC = 5
      READ_TIMEOUT_SEC = 10

      # Transport failures GitHub being slow/unreachable can produce. Mapped
      # to Hive::Error so the operator sees the friendly 422 error page
      # ("could not reach GitHub") instead of a blank 500 — the same policy
      # the Telegram validator applies to its transport errors.
      NETWORK_ERRORS = [
        Net::OpenTimeout, Net::ReadTimeout, SocketError,
        Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, IOError
      ].freeze

      def initialize(config:, http: Net::HTTP)
        @config = config
        @http = http
      end

      def configured?
        !client_id.to_s.empty? && !owner.to_s.empty?
      end

      # Begin a device authorization. Returns the GitHub payload Hash:
      # "device_code", "user_code", "verification_uri", "expires_in" (sec),
      # "interval" (minimum seconds between polls). The default scope only
      # identifies the operator; the Rails web app passes "repo" so the
      # granted token can also list/clone the operator's repositories.
      def start_device_flow(scope: "read:user")
        body = post_form(DEVICE_CODE_URL, "GitHub device authorization",
                         client_id: client_id, scope: scope)
        raise Hive::Error, "GitHub device authorization failed: #{body["error_description"] || body["error"]}" if body["error"]

        %w[device_code user_code verification_uri expires_in interval].each do |key|
          raise Hive::Error, "GitHub device authorization response missing #{key}" if body[key].to_s.empty?
        end
        body
      end

      # Poll the token endpoint once for the device grant. Returns:
      #   { state: :ok, login: "alice", token: "gho_..." } — authorized
      #   { state: :pending }                  — operator hasn't approved yet
      #   { state: :slow_down, interval: 10 }  — back off to the new interval
      #   { state: :denied }                   — operator cancelled the grant
      #   { state: :expired }                  — device code expired; restart
      # Anything else raises Hive::Error. GitHub reports all of these as HTTP
      # 200 with an `error` field, not via status codes. The granted token is
      # returned so callers that asked for a broader scope (the Rails web
      # app's repo listing) can keep it; callers that only gate on identity
      # may ignore it.
      def poll_device_flow(device_code)
        body = post_form(TOKEN_URL, "GitHub device grant poll",
                         client_id: client_id, device_code: device_code, grant_type: GRANT_TYPE)
        case body["error"]
        when nil
          token = body["access_token"]
          raise Hive::Error, "GitHub device grant returned no access_token" if token.to_s.empty?

          { state: :ok, login: login_for_token(token), token: token }
        when "authorization_pending" then { state: :pending }
        when "slow_down" then { state: :slow_down, interval: body.fetch("interval", 5).to_i }
        when "access_denied" then { state: :denied }
        when "expired_token" then { state: :expired }
        else
          raise Hive::Error, "GitHub device grant failed: #{body["error_description"] || body["error"]}"
        end
      end

      def owner?(login)
        login.to_s.downcase == owner.to_s.downcase
      end

      private

      def http_timeouts
        { use_ssl: true, open_timeout: OPEN_TIMEOUT_SEC, read_timeout: READ_TIMEOUT_SEC }
      end

      def post_form(url, context, **fields)
        req = Net::HTTP::Post.new(url)
        req["Accept"] = "application/json"
        req.set_form_data(**fields)
        res = request(req, url, context)
        raise Hive::Error, "#{context} failed (HTTP #{res.code})" unless res.is_a?(Net::HTTPSuccess)

        JSON.parse(res.body)
      rescue JSON::ParserError
        raise Hive::Error, "#{context} returned an unparseable response"
      end

      def login_for_token(token)
        req = Net::HTTP::Get.new(USER_URL)
        req["Accept"] = "application/vnd.github+json"
        req["Authorization"] = "Bearer #{token}"
        res = request(req, USER_URL, "GitHub user lookup")
        raise Hive::Error, "GitHub user lookup failed (HTTP #{res.code})" unless res.is_a?(Net::HTTPSuccess)

        login = JSON.parse(res.body)["login"]
        raise Hive::Error, "GitHub user lookup returned no login" if login.to_s.empty?

        login
      rescue JSON::ParserError
        raise Hive::Error, "GitHub user lookup returned an unparseable response"
      end

      def request(req, url, context)
        @http.start(url.host, url.port, **http_timeouts) { |http| http.request(req) }
      rescue *NETWORK_ERRORS => e
        raise Hive::Error, "#{context}: could not reach GitHub (#{e.class}: #{e.message})"
      end

      def client_id
        @config.dig("github", "client_id")
      end

      def owner
        @config.dig("github", "owner")
      end
    end
  end
end
