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
        res = @http.start(TOKEN_URL.host, TOKEN_URL.port, use_ssl: true) { |http| http.request(req) }
        token = JSON.parse(res.body).fetch("access_token")
        login_for_token(token)
      end

      def owner?(login)
        login.to_s.downcase == owner.to_s.downcase
      end

      def new_state
        SecureRandom.hex(24)
      end

      private

      def login_for_token(token)
        req = Net::HTTP::Get.new(USER_URL)
        req["Accept"] = "application/vnd.github+json"
        req["Authorization"] = "Bearer #{token}"
        res = @http.start(USER_URL.host, USER_URL.port, use_ssl: true) { |http| http.request(req) }
        JSON.parse(res.body).fetch("login")
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
