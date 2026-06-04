require "test_helper"
require "rack/test"
require "net/http"
require "hive/web/github_auth"

# U2's make-or-break control: the GitHub OAuth callback in app.rb must reject a
# mismatched state, a denied consent, and a *non-owner* login — and admit only
# the configured owner. Earlier suites swapped in FakeGithubAuth and only drove
# the owner=200 path, so the real `exchange_code` http seam and every 403 branch
# went unexercised. This drives the *real* GithubAuth against a fake http
# transport so the box's primary authz gate is proven, not a stub's
# reimplementation of `owner?`.
class WebGithubAuthFlowTest < Minitest::Test
  include Rack::Test::Methods
  include HiveTestHelper

  # Returns the token response for github.com and the user response for
  # api.github.com so the callback's token-then-user chain runs end to end.
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

  def http_ok(body)
    res = Net::HTTPOK.new("1.1", "200", "OK")
    res.instance_variable_set(:@read, true)
    res.define_singleton_method(:body) { body }
    res
  end

  def app
    @app
  end

  def setup
    @tmp = Dir.mktmpdir("hive-web-oauth")
    @old_env = {
      "HIVE_HOME" => ENV["HIVE_HOME"],
      "HOME" => ENV["HOME"],
      "HIVEBOX_SESSION_SECRET" => ENV["HIVEBOX_SESSION_SECRET"],
      "HIVEBOX_GITHUB_CLIENT_SECRET" => ENV["HIVEBOX_GITHUB_CLIENT_SECRET"]
    }
    ENV["HIVE_HOME"] = @tmp
    ENV["HOME"] = @tmp
    ENV["HIVEBOX_SESSION_SECRET"] = "x" * 64
    ENV["HIVEBOX_GITHUB_CLIENT_SECRET"] = "secret"
    File.write(File.join(@tmp, "config.yml"), {
      "registered_projects" => [],
      "web" => { "origin" => "http://127.0.0.1", "github" => { "owner" => "alice", "client_id" => "client" } }
    }.to_yaml)
    load File.expand_path("../../../lib/hive/web/app.rb", __dir__)
    @app = Hive::Web::App
  end

  def teardown
    @old_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.rm_rf(@tmp)
  end

  def install_auth(login:)
    @app.set :github_auth, Hive::Web::GithubAuth.new(
      config: Hive::Config.load_global_web,
      http: FakeHttp.new(
        token: http_ok(JSON.generate("access_token" => "tok")),
        user: http_ok(JSON.generate("login" => login))
      )
    )
  end

  # Establish a valid OAuth state in the session via the real /auth/github
  # redirect, then return the state value the app stored.
  def begin_oauth
    get "/auth/github", {}, "HTTP_HOST" => "127.0.0.1"
    last_response["Location"][/state=([^&]+)/, 1]
  end

  def test_state_mismatch_is_denied
    install_auth(login: "alice")
    begin_oauth

    get "/auth/github/callback", { "code" => "c", "state" => "forged" }, "HTTP_HOST" => "127.0.0.1"

    assert_equal 403, last_response.status
    assert_match(/Invalid OAuth state/, last_response.body)
  end

  def test_denied_consent_is_surfaced
    install_auth(login: "alice")
    state = begin_oauth

    get "/auth/github/callback",
        { "state" => state, "error" => "access_denied", "error_description" => "The user denied" },
        "HTTP_HOST" => "127.0.0.1"

    assert_equal 403, last_response.status
    assert_match(/sign-in failed/, last_response.body)
  end

  def test_non_owner_is_denied
    install_auth(login: "mallory")
    state = begin_oauth

    get "/auth/github/callback", { "code" => "c", "state" => state }, "HTTP_HOST" => "127.0.0.1"

    assert_equal 403, last_response.status, "a second GitHub account must be denied (U2)"
    assert_match(/is not allowed/, last_response.body)
  end

  def test_owner_is_admitted
    install_auth(login: "alice")
    state = begin_oauth

    get "/auth/github/callback", { "code" => "c", "state" => state }, "HTTP_HOST" => "127.0.0.1"

    assert_equal 302, last_response.status
    assert_equal "http://127.0.0.1/", last_response["Location"]
  end
end
