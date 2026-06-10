require "test_helper"
require "rack/test"
require "net/http"
require "hive/web/github_auth"

# U2's make-or-break control: the GitHub device-flow gate in app.rb must admit
# only the configured owner and surface every failure (denied grant, expired
# code, non-owner login) as a readable page — never a session. This drives the
# *real* GithubAuth against a fake http transport so the box's primary authz
# gate is proven end to end (start → wait-page poll → grant), not a stub's
# reimplementation of `owner?`.
class WebGithubAuthFlowTest < Minitest::Test
  include Rack::Test::Methods
  include HiveTestHelper

  # Routes on request path: device-code endpoint, token (poll) endpoint, and
  # the api.github.com user lookup.
  class FakeHttp
    def initialize(device:, token:, user:)
      @device = device
      @token = token
      @user = user
    end

    def start(host, _port, **_opts)
      @host = host
      yield self
    end

    def request(req)
      return @user if @host == "api.github.com"

      req.path.include?("/login/device/code") ? @device : @token
    end
  end

  DEVICE_BODY = JSON.generate(
    "device_code" => "dev-1", "user_code" => "ABCD-1234",
    "verification_uri" => "https://github.com/login/device",
    "expires_in" => 900,
    # interval 0 → the first GET /auth/github/wait polls immediately, so the
    # flow needs no clock manipulation.
    "interval" => 0
  )

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
      "HIVEBOX_SESSION_SECRET" => ENV["HIVEBOX_SESSION_SECRET"]
    }
    ENV["HIVE_HOME"] = @tmp
    ENV["HOME"] = @tmp
    ENV["HIVEBOX_SESSION_SECRET"] = "x" * 64
    File.write(File.join(@tmp, "config.yml"), {
      "registered_projects" => [],
      "web" => { "origin" => "http://127.0.0.1", "github" => { "owner" => "alice", "client_id" => "client" } }
    }.to_yaml)
    require "hive/web/app"
    Hive::Web::App.reconfigure!
    @app = Hive::Web::App
  end

  def teardown
    @old_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.rm_rf(@tmp)
  end

  def install_auth(login: "alice", token_body: nil)
    token_body ||= JSON.generate("access_token" => "tok")
    @app.set :github_auth, Hive::Web::GithubAuth.new(
      config: Hive::Config.load_global_web,
      http: FakeHttp.new(
        device: http_ok(DEVICE_BODY),
        token: http_ok(token_body),
        user: http_ok(JSON.generate("login" => login))
      )
    )
  end

  # Start the device flow from the real login form: pull the CSRF token off
  # /login, POST /auth/github, and follow to the waiting page path.
  def begin_device_flow
    get "/login", {}, "HTTP_HOST" => "127.0.0.1"
    token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    post "/auth/github", { "authenticity_token" => token }, "HTTP_HOST" => "127.0.0.1"
    assert_equal 302, last_response.status, "starting the device flow must redirect to the waiting page"
    assert_match %r{/auth/github/wait\z}, last_response["Location"]
  end

  def test_start_without_csrf_token_is_rejected
    install_auth
    post "/auth/github", {}, "HTTP_HOST" => "127.0.0.1"

    assert_equal 403, last_response.status, "the device-flow start is a mutation and must ride verify_csrf!"
  end

  def test_wait_without_started_flow_redirects_to_login
    install_auth
    get "/auth/github/wait", {}, "HTTP_HOST" => "127.0.0.1"

    assert_equal 302, last_response.status
    assert_match %r{/login\z}, last_response["Location"]
  end

  def test_pending_grant_keeps_showing_the_user_code
    install_auth(token_body: JSON.generate("error" => "authorization_pending"))
    begin_device_flow

    get "/auth/github/wait", {}, "HTTP_HOST" => "127.0.0.1"

    assert_equal 200, last_response.status
    assert_match(/ABCD-1234/, last_response.body, "the waiting page must show the user code while pending")
    assert_match(/github\.com\/login\/device/, last_response.body)
    refute_match(/Log out/, last_response.body, "a pending grant must not produce a session")
  end

  def test_denied_grant_is_surfaced
    install_auth(token_body: JSON.generate("error" => "access_denied"))
    begin_device_flow

    get "/auth/github/wait", {}, "HTTP_HOST" => "127.0.0.1"

    assert_equal 403, last_response.status
    assert_match(/sign-in failed/, last_response.body)
  end

  def test_expired_device_code_is_surfaced
    install_auth(token_body: JSON.generate("error" => "expired_token"))
    begin_device_flow

    get "/auth/github/wait", {}, "HTTP_HOST" => "127.0.0.1"

    assert_equal 403, last_response.status
    assert_match(/expired/, last_response.body)
  end

  def test_non_owner_is_denied
    install_auth(login: "mallory")
    begin_device_flow

    get "/auth/github/wait", {}, "HTTP_HOST" => "127.0.0.1"

    assert_equal 403, last_response.status, "a second GitHub account must be denied (U2)"
    assert_match(/is not allowed/, last_response.body)

    get "/", {}, "HTTP_HOST" => "127.0.0.1"
    assert_equal 302, last_response.status, "a denied login must not leave a usable session"
  end

  def test_owner_is_admitted
    install_auth(login: "alice")
    begin_device_flow

    get "/auth/github/wait", {}, "HTTP_HOST" => "127.0.0.1"

    assert_equal 302, last_response.status
    assert_equal "http://127.0.0.1/", last_response["Location"]

    get "/", {}, "HTTP_HOST" => "127.0.0.1"
    assert_equal 200, last_response.status, "the owner's session must survive into the status grid"
  end
end
