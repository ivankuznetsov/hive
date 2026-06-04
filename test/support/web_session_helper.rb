require "rack/test"

# Shared helpers for the Hive::Web Rack::Test route tests: boot a fresh app
# against a tmp HIVE_HOME, log a session in through the (replaceable) GitHub
# auth, and extract CSRF tokens from rendered forms so state-changing POSTs
# pass `verify_csrf!`.
module WebSessionHelper
  include Rack::Test::Methods

  FakeGithubAuth = Struct.new(:owner_login) do
    def configured? = true
    def new_state = "test-oauth-state"
    def authorize_url(state:) = "https://github.test/authorize?state=#{state}"
    def exchange_code(_code) = owner_login
    def owner?(login) = login == owner_login
  end

  def app
    @app
  end

  # (Re)load the Sinatra app so its `configure` block reads the current
  # config.yml. Mirrors test/unit/web/app_test.rb.
  def boot_web_app
    ENV["HIVEBOX_SESSION_SECRET"] ||= "x" * 64
    load File.expand_path("../../../lib/hive/web/app.rb", __FILE__)
    @app = Hive::Web::App
    @app.set :github_auth, FakeGithubAuth.new("alice")
    @app
  end

  # Establish an authenticated session via the OAuth callback. Rack::Test
  # carries the session cookie across subsequent requests.
  def login!(host: "127.0.0.1")
    get "/auth/github", {}, "HTTP_HOST" => host
    get "/auth/github/callback", { "code" => "ok", "state" => "test-oauth-state" }, "HTTP_HOST" => host
    follow_redirect! if last_response.redirect?
  end

  # Pull the authenticity_token out of the first form on the given page so a
  # POST can satisfy verify_csrf!.
  def csrf_token_from(path, host: "127.0.0.1")
    get path, {}, "HTTP_HOST" => host
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
  end
end
