require "json"
require "net/http"
require "uri"
require "hive"
require "hive/screenote/http"

module Hive
  module Screenote
    class OAuthClient
      DEFAULT_BASE_URL = "https://screenote.ai".freeze
      SCOPE = "mcp_read mcp_write".freeze

      Discovery = Struct.new(
        :issuer, :authorization_endpoint, :token_endpoint, :registration_endpoint,
        :revocation_endpoint, :mcp_resource,
        keyword_init: true
      )

      attr_reader :base_url

      def initialize(base_url: DEFAULT_BASE_URL, http: Net::HTTP)
        @base_url = base_url.to_s.strip.delete_suffix("/")
        @http = http
      end

      def self.discover(base_url = DEFAULT_BASE_URL, http: Net::HTTP)
        new(base_url: base_url, http: http).discover
      end

      def discover
        auth = get_json("/.well-known/oauth-authorization-server", "Screenote OAuth discovery")
        resource = get_json("/.well-known/oauth-protected-resource", "Screenote MCP resource discovery")

        Discovery.new(
          issuer: required(auth, "issuer", "Screenote OAuth discovery"),
          authorization_endpoint: required(auth, "authorization_endpoint", "Screenote OAuth discovery"),
          token_endpoint: required(auth, "token_endpoint", "Screenote OAuth discovery"),
          registration_endpoint: required(auth, "registration_endpoint", "Screenote OAuth discovery"),
          revocation_endpoint: required(auth, "revocation_endpoint", "Screenote OAuth discovery"),
          mcp_resource: required(resource, "resource", "Screenote MCP resource discovery")
        )
      end

      def register(redirect_uri, metadata:)
        payload = {
          client_name: "hive",
          redirect_uris: [ redirect_uri ],
          grant_types: %w[authorization_code refresh_token],
          response_types: %w[code],
          scope: SCOPE,
          token_endpoint_auth_method: "none"
        }
        body = post_json(metadata.registration_endpoint, payload, "Screenote dynamic client registration")
        required(body, "client_id", "Screenote dynamic client registration")
        body
      end

      def authorize_url(metadata:, client_id:, redirect_uri:, code_challenge:, state:, scope: SCOPE)
        uri = URI(metadata.authorization_endpoint)
        params = URI.decode_www_form(uri.query.to_s)
        params.concat(
          [
            [ "response_type", "code" ],
            [ "client_id", client_id ],
            [ "redirect_uri", redirect_uri ],
            [ "scope", scope ],
            [ "state", state ],
            [ "code_challenge", code_challenge ],
            [ "code_challenge_method", "S256" ]
          ]
        )
        uri.query = URI.encode_www_form(params)
        uri.to_s
      end

      def exchange_code(code:, verifier:, redirect_uri:, client_id:, metadata:)
        body = post_form(
          metadata.token_endpoint,
          "Screenote token exchange",
          grant_type: "authorization_code",
          code: code,
          redirect_uri: redirect_uri,
          client_id: client_id,
          code_verifier: verifier
        )
        required(body, "access_token", "Screenote token exchange")
        body
      end

      def revoke(token:, metadata:, client_id: nil)
        fields = { token: token }
        fields[:client_id] = client_id if client_id
        post_form(metadata.revocation_endpoint, "Screenote token revocation", **fields)
        true
      end

      private

      def get_json(path_or_url, context)
        req = Net::HTTP::Get.new(uri_for(path_or_url))
        req["Accept"] = "application/json"
        parse_json_response(request(req, context), context)
      end

      def post_json(path_or_url, payload, context)
        uri = uri_for(path_or_url)
        req = Net::HTTP::Post.new(uri)
        req["Accept"] = "application/json"
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(payload)
        parse_json_response(request(req, context), context)
      end

      def post_form(path_or_url, context, **fields)
        req = Net::HTTP::Post.new(uri_for(path_or_url))
        req["Accept"] = "application/json"
        req.set_form_data(fields)
        parse_json_response(request(req, context), context)
      end

      def request(req, context)
        Hive::Screenote::Http.request(http: @http, request: req, uri: req.uri, context: context)
      end

      def parse_json_response(response, context)
        Hive::Screenote::Http.parse_json_object(response.body, context, empty_object: true)
      end

      def required(hash, key, context)
        value = hash[key]
        raise Hive::Error, "#{context} response missing #{key}" if value.to_s.strip.empty?

        value
      end

      def uri_for(path_or_url)
        text = path_or_url.to_s
        return URI(text) if text.match?(%r{\Ahttps?://})

        URI("#{base_url}#{text.start_with?("/") ? text : "/#{text}"}")
      end
    end
  end
end
