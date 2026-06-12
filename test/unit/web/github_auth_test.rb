require "test_helper"
require "net/http"
require "hive/web/github_auth"

class GithubAuthTest < Minitest::Test
  # Drives the `http:` DI seam without a network round-trip. Routes on the
  # request path (device-code vs token vs user endpoint) and RECORDS every
  # outgoing request so tests can assert the wire contract (path, form
  # fields, headers) — not just response handling.
  class FakeHttp
    Recorded = Struct.new(:host, :path, :body, :headers)

    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def start(host, _port, **_opts)
      @host = host
      yield self
    end

    def request(req)
      @requests << Recorded.new(@host, req.path, req.body.to_s, req.to_hash)
      key =
        if @host == "api.github.com" then :user
        elsif req.path.include?("/login/device/code") then :device
        else :token
        end
      @responses.fetch(key)
    end
  end

  # An http seam that raises a transport error on first contact, to prove
  # network failures map to Hive::Error (friendly 422) not a blank 500.
  class TimeoutHttp
    def start(*) = raise Net::OpenTimeout, "execution expired"
  end

  def self.http_ok(body)
    res = Net::HTTPOK.new("1.1", "200", "OK")
    res.instance_variable_set(:@read, true)
    res.define_singleton_method(:body) { body }
    res
  end

  DEVICE_OK = JSON.generate(
    "device_code" => "dev-1", "user_code" => "ABCD-1234",
    "verification_uri" => "https://github.com/login/device",
    "expires_in" => 899, "interval" => 5
  )

  def build_auth(device: DEVICE_OK, token: nil, user: nil)
    http = FakeHttp.new(
      device: self.class.http_ok(device),
      token: self.class.http_ok(token.to_s),
      user: self.class.http_ok(user.to_s)
    )
    auth = Hive::Web::GithubAuth.new(
      config: { "github" => { "client_id" => "cid", "owner" => "octo" } },
      http: http
    )
    [ auth, http ]
  end

  def test_start_device_flow_returns_codes_and_sends_client_id_and_scope
    auth, http = build_auth

    device = auth.start_device_flow

    assert_equal "ABCD-1234", device["user_code"], "user_code must come from the GitHub payload"
    assert_equal "dev-1", device["device_code"]
    req = http.requests.first
    assert_equal "/login/device/code", req.path, "device authorization must hit the device-code endpoint"
    assert_match(/client_id=cid/, req.body)
    assert_match(/scope=read%3Auser/, req.body)
  end

  def test_start_device_flow_raises_on_error_payload
    auth, = build_auth(device: JSON.generate("error" => "unauthorized_client", "error_description" => "device flow disabled"))

    error = assert_raises(Hive::Error) { auth.start_device_flow }
    assert_match(/device flow disabled/, error.message)
  end

  def test_start_device_flow_raises_on_missing_fields
    auth, = build_auth(device: JSON.generate("user_code" => "ABCD-1234"))

    error = assert_raises(Hive::Error) { auth.start_device_flow }
    assert_match(/missing device_code/, error.message)
  end

  def test_poll_grants_login_and_sends_device_grant_contract
    auth, http = build_auth(
      token: JSON.generate("access_token" => "tok"),
      user: JSON.generate("login" => "octo")
    )

    result = auth.poll_device_flow("dev-1")

    assert_equal({ state: :ok, login: "octo", token: "tok" }, result,
                 "the granted token must be returned for callers that need API access (repo listing)")
    token_req = http.requests.find { |r| r.path.include?("/login/oauth/access_token") }
    assert token_req, "the poll must hit the token endpoint"
    assert_match(/device_code=dev-1/, token_req.body)
    assert_match(/grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code/, token_req.body)
    user_req = http.requests.find { |r| r.host == "api.github.com" }
    assert_equal "Bearer tok", user_req.headers["authorization"].first, "the user lookup must carry the granted token"
  end

  def test_poll_maps_pending_slow_down_denied_and_expired
    { "authorization_pending" => { state: :pending },
      "access_denied" => { state: :denied },
      "expired_token" => { state: :expired } }.each do |error, expected|
      auth, = build_auth(token: JSON.generate("error" => error))
      assert_equal expected, auth.poll_device_flow("dev-1"), "GitHub error #{error} must map to #{expected[:state]}"
    end

    auth, = build_auth(token: JSON.generate("error" => "slow_down", "interval" => 11))
    assert_equal({ state: :slow_down, interval: 11 }, auth.poll_device_flow("dev-1"))
  end

  def test_poll_raises_on_unknown_error_payload
    auth, = build_auth(token: JSON.generate("error" => "incorrect_device_code"))

    error = assert_raises(Hive::Error) { auth.poll_device_flow("dev-1") }
    assert_match(/incorrect_device_code/, error.message)
  end

  def test_poll_raises_on_unparseable_token_response
    # A proxy/error page returns 200 with non-JSON; JSON.parse raises and the
    # rescue must surface a clean Hive::Error, not a raw JSON::ParserError.
    auth, = build_auth(token: "<html>not json</html>")

    error = assert_raises(Hive::Error) { auth.poll_device_flow("dev-1") }
    assert_match(/unparseable response/, error.message)
  end

  def test_poll_raises_on_unparseable_user_response
    auth, = build_auth(
      token: JSON.generate("access_token" => "tok"),
      user: "<html>not json</html>"
    )

    error = assert_raises(Hive::Error) { auth.poll_device_flow("dev-1") }
    assert_match(/user lookup returned an unparseable response/, error.message)
  end

  def test_network_timeouts_map_to_hive_error
    auth = Hive::Web::GithubAuth.new(
      config: { "github" => { "client_id" => "cid", "owner" => "octo" } },
      http: TimeoutHttp.new
    )

    error = assert_raises(Hive::Error) { auth.start_device_flow }
    assert_match(/could not reach GitHub/, error.message)
  end

  def test_configured_requires_client_id_only_and_ownerless_is_claimable
    auth = Hive::Web::GithubAuth.new(config: { "github" => { "client_id" => "cid", "owner" => "octo" } })
    assert auth.configured?, "device flow needs no client secret — client_id suffices"
    refute auth.claimable?, "a pinned owner keeps the gate closed"

    no_owner = Hive::Web::GithubAuth.new(config: { "github" => { "client_id" => "cid" } })
    assert no_owner.configured?, "an ownerless box can still START sign-in (the first login claims it)"
    assert no_owner.claimable?

    no_client = Hive::Web::GithubAuth.new(config: { "github" => {} })
    refute no_client.configured?, "without a client_id no flow can start"
  end

  def test_owner_match_is_case_insensitive
    auth = Hive::Web::GithubAuth.new(
      config: { "github" => { "owner" => "Alice", "client_id" => "id" } }
    )

    assert auth.owner?("alice")
    refute auth.owner?("bob")
  end
end
