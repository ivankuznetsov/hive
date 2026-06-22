require "test_helper"
require "net/http"
require "hive/screenote/oauth_client"

class ScreenoteOAuthClientTest < Minitest::Test
  class FakeHttp
    Recorded = Struct.new(:host, :path, :body, :headers, :method, :options)

    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def start(host, _port, **options)
      @host = host
      @options = options
      yield self
    end

    def request(req)
      @requests << Recorded.new(@host, req.path, req.body.to_s, req.to_hash, req.method, @options)
      response = @responses.fetch(req.path)
      response.respond_to?(:call) ? response.call(req) : response
    end
  end

  class TimeoutHttp
    def start(*) = raise Net::OpenTimeout, "execution expired"
  end

  def self.http_response(klass, code, message, body)
    response = klass.new("1.1", code, message)
    response.instance_variable_set(:@read, true)
    response.define_singleton_method(:body) { body }
    response
  end

  def self.ok(body) = http_response(Net::HTTPOK, "200", "OK", body)

  def self.no_content = http_response(Net::HTTPNoContent, "204", "No Content", "")

  def self.bad_request(body = "") = http_response(Net::HTTPBadRequest, "400", "Bad Request", body)

  def auth_metadata
    {
      "issuer" => "https://screenote.test",
      "authorization_endpoint" => "https://screenote.test/oauth/authorize",
      "token_endpoint" => "https://screenote.test/oauth/token",
      "registration_endpoint" => "https://screenote.test/oauth/register",
      "revocation_endpoint" => "https://screenote.test/oauth/revoke"
    }
  end

  def discovery
    Hive::Screenote::OAuthClient::Discovery.new(
      issuer: "https://screenote.test",
      authorization_endpoint: "https://screenote.test/oauth/authorize",
      token_endpoint: "https://screenote.test/oauth/token",
      registration_endpoint: "https://screenote.test/oauth/register",
      revocation_endpoint: "https://screenote.test/oauth/revoke",
      mcp_resource: "https://screenote.test/mcp"
    )
  end

  def build_client(responses)
    http = FakeHttp.new(responses)
    client = Hive::Screenote::OAuthClient.new(base_url: "https://screenote.test/", http: http)
    [ client, http ]
  end

  def test_discover_parses_authorization_and_resource_metadata
    client, http = build_client(
      "/.well-known/oauth-authorization-server" => self.class.ok(JSON.generate(auth_metadata)),
      "/.well-known/oauth-protected-resource" => self.class.ok(JSON.generate("resource" => "https://screenote.test/mcp"))
    )

    metadata = client.discover

    assert_equal "https://screenote.test", metadata.issuer
    assert_equal "https://screenote.test/mcp", metadata.mcp_resource
    assert_equal [ "/.well-known/oauth-authorization-server", "/.well-known/oauth-protected-resource" ],
                 http.requests.map(&:path)
    assert_equal true, http.requests.first.options[:use_ssl]
    assert_equal Hive::Screenote::OAuthClient::OPEN_TIMEOUT_SEC, http.requests.first.options[:open_timeout]
  end

  def test_class_discover_uses_the_same_protocol
    http = FakeHttp.new(
      "/.well-known/oauth-authorization-server" => self.class.ok(JSON.generate(auth_metadata)),
      "/.well-known/oauth-protected-resource" => self.class.ok(JSON.generate("resource" => "https://screenote.test/mcp"))
    )

    metadata = Hive::Screenote::OAuthClient.discover("https://screenote.test", http: http)

    assert_equal "https://screenote.test/oauth/token", metadata.token_endpoint
  end

  def test_discover_rejects_missing_required_fields
    client, = build_client(
      "/.well-known/oauth-authorization-server" => self.class.ok(JSON.generate(auth_metadata.except("issuer"))),
      "/.well-known/oauth-protected-resource" => self.class.ok(JSON.generate("resource" => "https://screenote.test/mcp"))
    )

    err = assert_raises(Hive::Error) { client.discover }
    assert_match(/missing issuer/, err.message)
  end

  def test_register_sends_public_client_metadata_and_parses_client_id
    client, http = build_client(
      "/oauth/register" => self.class.ok(JSON.generate("client_id" => "client-123", "redirect_uris" => [ "http://127.0.0.1:321/callback" ]))
    )

    payload = client.register("http://127.0.0.1:321/callback", metadata: discovery)

    assert_equal "client-123", payload["client_id"]
    req = http.requests.first
    sent = JSON.parse(req.body)
    assert_equal "POST", req.method
    assert_equal [ "http://127.0.0.1:321/callback" ], sent["redirect_uris"]
    assert_equal %w[authorization_code refresh_token], sent["grant_types"]
    assert_equal "mcp_read mcp_write", sent["scope"]
    assert_equal "none", sent["token_endpoint_auth_method"]
    assert_equal "application/json", req.headers["content-type"].first
  end

  def test_register_requires_client_id_and_object_response
    client, = build_client("/oauth/register" => self.class.ok(JSON.generate("redirect_uris" => [])))

    err = assert_raises(Hive::Error) { client.register("http://127.0.0.1/callback", metadata: discovery) }
    assert_match(/missing client_id/, err.message)

    client, = build_client("/oauth/register" => self.class.ok(JSON.generate([])))
    err = assert_raises(Hive::Error) { client.register("http://127.0.0.1/callback", metadata: discovery) }
    assert_match(/non-object response/, err.message)
  end

  def test_authorize_url_includes_pkce_state_scope_and_existing_query
    metadata = discovery
    metadata.authorization_endpoint = "https://screenote.test/oauth/authorize?prompt=consent"

    url = Hive::Screenote::OAuthClient.new.authorize_url(
      metadata: metadata,
      client_id: "client-123",
      redirect_uri: "http://127.0.0.1:321/callback",
      code_challenge: "challenge",
      state: "state-123"
    )
    params = URI.decode_www_form(URI(url).query).to_h

    assert_equal "consent", params["prompt"]
    assert_equal "code", params["response_type"]
    assert_equal "client-123", params["client_id"]
    assert_equal "challenge", params["code_challenge"]
    assert_equal "S256", params["code_challenge_method"]
    assert_equal "mcp_read mcp_write", params["scope"]
    assert_equal "state-123", params["state"]
  end

  def test_exchange_code_posts_verifier_and_returns_token_payload
    token_body = JSON.generate(
      "access_token" => "access-123",
      "expires_in" => 31_536_000,
      "refresh_token" => "refresh-123",
      "token_type" => "Bearer"
    )
    client, http = build_client("/oauth/token" => self.class.ok(token_body))

    payload = client.exchange_code(
      code: "code-123",
      verifier: "verifier-123",
      redirect_uri: "http://127.0.0.1:321/callback",
      client_id: "client-123",
      metadata: discovery
    )

    assert_equal "access-123", payload["access_token"]
    body = http.requests.first.body
    assert_match(/grant_type=authorization_code/, body)
    assert_match(/code=code-123/, body)
    assert_match(/client_id=client-123/, body)
    assert_match(/code_verifier=verifier-123/, body)
  end

  def test_exchange_code_requires_access_token
    client, = build_client("/oauth/token" => self.class.ok(JSON.generate("token_type" => "Bearer")))

    err = assert_raises(Hive::Error) do
      client.exchange_code(code: "code", verifier: "verifier", redirect_uri: "http://127.0.0.1/callback",
                           client_id: "client", metadata: discovery)
    end
    assert_match(/missing access_token/, err.message)
  end

  def test_revoke_posts_token_and_accepts_empty_success_response
    client, http = build_client("/oauth/revoke" => self.class.no_content)

    assert client.revoke(token: "access-123", client_id: "client-123", metadata: discovery)
    body = http.requests.first.body
    assert_match(/token=access-123/, body)
    assert_match(/client_id=client-123/, body)
  end

  def test_http_status_json_and_network_errors_map_to_hive_error
    client, = build_client("/oauth/token" => self.class.bad_request)
    err = assert_raises(Hive::Error) do
      client.exchange_code(code: "code", verifier: "verifier", redirect_uri: "http://127.0.0.1/callback",
                           client_id: "client", metadata: discovery)
    end
    assert_match(/HTTP 400/, err.message)

    client, = build_client("/oauth/token" => self.class.ok("<html>"))
    err = assert_raises(Hive::Error) do
      client.exchange_code(code: "code", verifier: "verifier", redirect_uri: "http://127.0.0.1/callback",
                           client_id: "client", metadata: discovery)
    end
    assert_match(/unparseable response/, err.message)

    client = Hive::Screenote::OAuthClient.new(base_url: "https://screenote.test", http: TimeoutHttp.new)
    err = assert_raises(Hive::Error) { client.discover }
    assert_match(/could not reach Screenote/, err.message)
  end
end
