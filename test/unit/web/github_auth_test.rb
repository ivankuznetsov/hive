require "test_helper"
require "net/http"
require "hive/web/github_auth"

class GithubAuthTest < Minitest::Test
  # Drives the `http:` DI seam without a network round-trip: returns the token
  # response for the github.com host and the user response for api.github.com,
  # so `exchange_code` exercises its real token-then-user request chain.
  class FakeHttp
    def initialize(token:, user:)
      @token = token
      @user = user
    end

    def start(host, _port, **_opts)
      @host = host
      yield self
    end

    def request(_req)
      @host == "api.github.com" ? @user : @token
    end
  end

  def self.http_ok(body)
    res = Net::HTTPOK.new("1.1", "200", "OK")
    res.instance_variable_set(:@read, true)
    res.define_singleton_method(:body) { body }
    res
  end

  def build_auth(token_body:, user_body:)
    Hive::Web::GithubAuth.new(
      config: { "origin" => "https://box.example", "github" => { "client_id" => "id", "owner" => "octo" } },
      http: FakeHttp.new(
        token: self.class.http_ok(token_body),
        user: self.class.http_ok(user_body)
      )
    )
  end

  def test_exchange_code_returns_login_on_success
    auth = build_auth(
      token_body: JSON.generate("access_token" => "tok"),
      user_body: JSON.generate("login" => "octo")
    )

    assert_equal "octo", auth.exchange_code("good-code")
  end

  def test_exchange_code_raises_on_error_payload
    auth = build_auth(
      token_body: JSON.generate("error" => "bad_verification_code"),
      user_body: JSON.generate("login" => "octo")
    )

    error = assert_raises(Hive::Error) { auth.exchange_code("stale-code") }
    assert_match(/bad_verification_code/, error.message)
  end
  def test_exchange_code_raises_on_unparseable_token_response
    # A proxy/error page returns 200 with non-JSON; JSON.parse raises and the
    # rescue must surface a clean Hive::Error, not a raw JSON::ParserError.
    auth = build_auth(
      token_body: "<html>not json</html>",
      user_body: JSON.generate("login" => "octo")
    )

    error = assert_raises(Hive::Error) { auth.exchange_code("good-code") }
    assert_match(/unparseable response/, error.message)
  end

  def test_exchange_code_raises_on_unparseable_user_response
    # The token leg parses fine but the user lookup returns non-JSON; the
    # second rescue must map that to a friendly Hive::Error too.
    auth = build_auth(
      token_body: JSON.generate("access_token" => "tok"),
      user_body: "<html>not json</html>"
    )

    error = assert_raises(Hive::Error) { auth.exchange_code("good-code") }
    assert_match(/user lookup returned an unparseable response/, error.message)
  end

  def test_authorize_url_contains_callback_and_state
    auth = Hive::Web::GithubAuth.new(
      config: {
        "origin" => "https://box.example",
        "github" => { "client_id" => "abc", "owner" => "octo" }
      }
    )

    url = auth.authorize_url(state: "state123")

    assert_match(%r{\Ahttps://github\.com/login/oauth/authorize\?}, url)
    assert_match(/client_id=abc/, url)
    assert_match(/state=state123/, url)
    assert_match(/redirect_uri=https%3A%2F%2Fbox\.example%2Fauth%2Fgithub%2Fcallback/, url)
  end

  def test_owner_match_is_case_insensitive
    auth = Hive::Web::GithubAuth.new(
      config: { "origin" => "http://localhost", "github" => { "owner" => "Alice", "client_id" => "id" } }
    )

    assert auth.owner?("alice")
    refute auth.owner?("bob")
  end
end
