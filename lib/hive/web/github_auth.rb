require "json"
require "net/http"
require "securerandom"
require "uri"

module Hive
  module Web
    class GithubAuth
      AUTHORIZE_URL = "https://github.com/login/oauth/authorize".freeze
      TOKEN_URL = URI("https://github.com/login/oauth/access_token")
      USER_URL = URI("https://api.github.com/user")

      # Bound both legs of every GitHub call. Net::HTTP defaults to a 60s read
      # timeout; on the box's small Puma pool a hung GitHub would pin a thread
      # for a full minute (or until the client gives up), so cap it tightly.
      OPEN_TIMEOUT_SEC = 5
      READ_TIMEOUT_SEC = 10

      def initialize(config:, http: Net::HTTP)
        @config = config
        @http = http
      end

      def configured?
        !client_id.to_s.empty? && !client_secret.to_s.empty? && !owner.to_s.empty?
      end

      def authorize_url(state:)
        query = URI.encode_www_form(
          client_id: client_id,
          redirect_uri: callback_url,
          scope: "read:user",
          state: state
        )
        "#{AUTHORIZE_URL}?#{query}"
      end

      def exchange_code(code)
        req = Net::HTTP::Post.new(TOKEN_URL)
        req["Accept"] = "application/json"
        req.set_form_data(
          client_id: client_id,
          client_secret: client_secret,
          code: code,
          redirect_uri: callback_url
        )
        res = @http.start(TOKEN_URL.host, TOKEN_URL.port, **http_timeouts) { |http| http.request(req) }
        raise Hive::Error, "GitHub token exchange failed (HTTP #{res.code})" unless res.is_a?(Net::HTTPSuccess)

        body = JSON.parse(res.body)
        # GitHub returns 200 with an `error` field on a bad/expired code
        # rather than a non-2xx status, so check the payload explicitly.
        raise Hive::Error, "GitHub token exchange failed: #{body["error_description"] || body["error"]}" if body["error"]

        token = body["access_token"]
        raise Hive::Error, "GitHub token exchange returned no access_token" if token.to_s.empty?

        login_for_token(token)
      rescue JSON::ParserError
        raise Hive::Error, "GitHub token exchange returned an unparseable response"
      end

      def owner?(login)
        login.to_s.downcase == owner.to_s.downcase
      end

      def new_state
        SecureRandom.hex(24)
      end

      private

      def http_timeouts
        { use_ssl: true, open_timeout: OPEN_TIMEOUT_SEC, read_timeout: READ_TIMEOUT_SEC }
      end

      def login_for_token(token)
        req = Net::HTTP::Get.new(USER_URL)
        req["Accept"] = "application/vnd.github+json"
        req["Authorization"] = "Bearer #{token}"
        res = @http.start(USER_URL.host, USER_URL.port, **http_timeouts) { |http| http.request(req) }
        raise Hive::Error, "GitHub user lookup failed (HTTP #{res.code})" unless res.is_a?(Net::HTTPSuccess)

        login = JSON.parse(res.body)["login"]
        raise Hive::Error, "GitHub user lookup returned no login" if login.to_s.empty?

        login
      rescue JSON::ParserError
        raise Hive::Error, "GitHub user lookup returned an unparseable response"
      end

      def client_id
        @config.dig("github", "client_id")
      end

      def client_secret
        ENV["HIVEBOX_GITHUB_CLIENT_SECRET"]
      end

      def owner
        @config.dig("github", "owner")
      end

      def callback_url
        "#{@config.fetch("origin").delete_suffix("/")}/auth/github/callback"
      end
    end
  end
end
