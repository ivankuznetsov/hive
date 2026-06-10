require "rack/test"

# Shared helpers for the Hive::Web Rack::Test route tests: boot a fresh app
# against a tmp HIVE_HOME, log a session in through the (replaceable) GitHub
# auth, and extract CSRF tokens from rendered forms so state-changing POSTs
# pass `verify_csrf!`.
module WebSessionHelper
  include Rack::Test::Methods

  # Device-flow shaped (see Hive::Web::GithubAuth): `interval => 0` lets the
  # first GET /auth/github/wait poll immediately, so login! needs no clock
  # manipulation; poll_device_flow grants the configured login right away.
  FakeGithubAuth = Struct.new(:owner_login) do
    def configured? = true

    def start_device_flow
      {
        "device_code" => "test-device-code",
        "user_code" => "ABCD-1234",
        "verification_uri" => "https://github.test/login/device",
        "expires_in" => 900,
        "interval" => 0
      }
    end

    def poll_device_flow(_device_code) = { state: :ok, login: owner_login }
    def owner?(login) = login == owner_login
  end

  def app
    @app
  end

  # Stop the shared StatusFeed poller thread after every web test. The app is a
  # require-once singleton, so an SSE test that lazily started the poller would
  # otherwise leak a background thread that keeps shelling out to Hive::Config
  # against a torn-down tmp HIVE_HOME — a cross-test race in the full suite.
  def teardown
    if defined?(Hive::Web::App) && Hive::Web::App.respond_to?(:settings) &&
       Hive::Web::App.settings.respond_to?(:status_feed)
      Hive::Web::App.settings.status_feed&.stop
    end
  rescue StandardError
    nil
  ensure
    super
  end

  # Boot the Sinatra app against the current config.yml. The app is
  # `require`d once (idempotent) and then `reconfigure!`d so its runtime
  # settings re-read config.yml each test. We deliberately do NOT `load`-
  # reload the class: under a reloaded Sinatra::Base subclass stdlib Coverage
  # drops line attribution for the inline route/helper/error blocks, leaving
  # app.rb's auth/OAuth/error code falsely "uncovered".
  def boot_web_app
    ENV["HIVEBOX_SESSION_SECRET"] ||= "x" * 64
    require "hive/web/app"
    Hive::Web::App.reconfigure!
    @app = Hive::Web::App
    @app.set :github_auth, FakeGithubAuth.new("alice")
    @app
  end

  # Establish an authenticated session via the device flow: start it from the
  # login form (CSRF-protected POST), then let the waiting page's immediate
  # poll (interval 0) grant the session. Rack::Test carries the session
  # cookie across subsequent requests.
  def login!(host: "127.0.0.1")
    token = csrf_token_from("/login", host: host)
    post "/auth/github", { "authenticity_token" => token }, "HTTP_HOST" => host
    # Explicit path request, NOT follow_redirect!: the redirect Location is an
    # absolute http://#{host}/... URL, and Rack::Test's cookie jar scopes the
    # session cookie to its default host (the requests above are path-only
    # with an HTTP_HOST header override) — following the absolute URL would
    # drop the cookie and the grant. The wait page polls once (interval 0)
    # and establishes the session.
    get "/auth/github/wait", {}, "HTTP_HOST" => host
  end

  # Pull the authenticity_token out of the first form on the given page so a
  # POST can satisfy verify_csrf!.
  def csrf_token_from(path, host: "127.0.0.1")
    get path, {}, "HTTP_HOST" => host
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
  end
end
