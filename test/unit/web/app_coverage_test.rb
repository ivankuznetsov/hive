require "test_helper"
require "rack/test"
require "hive/web/app"
require "hive/web/dispatcher"

# Drives app.rb's class-body routes/helpers/error-handlers against the
# REQUIRED (never load-reloaded) Hive::Web::App so stdlib Coverage attributes
# their line execution. The other web suites reload app.rb via boot_web_app,
# under which Sinatra's inline route blocks lose line attribution; this suite
# keeps the single required instance so the auth gate, the OAuth callback, the
# error handlers, and find_project! are provably exercised.
class WebAppCoverageTest < Minitest::Test
  include Rack::Test::Methods
  include HiveTestHelper

  # `returns` is the login exchange_code resolves to; `owner` is the allowed
  # account. They differ in the non-owner test so owner? actually rejects.
  FakeAuth = Struct.new(:owner, :configured, :returns) do
    def configured? = configured
    def new_state = "real-state-value"
    def authorize_url(state:) = "https://gh.test/authorize?state=#{state}"
    def exchange_code(_code) = (returns || owner)
    def owner?(login) = login == owner
  end

  # A status feed that reports one project so find_project! resolves and
  # task_row can be probed without the filesystem.
  class StubFeed
    def snapshot
      { "schema" => "hive-status",
        "projects" => [ { "name" => "demo", "tasks" => [ { "slug" => "task-a", "folder" => nil } ] } ] }
    end

    def each_snapshot(*, **) = nil
  end

  def app = Hive::Web::App

  def setup
    @tmp = Dir.mktmpdir("hive-app-cov")
    @old = %w[HIVE_HOME HOME HIVEBOX_SESSION_SECRET].to_h { |k| [ k, ENV[k] ] }
    ENV["HIVE_HOME"] = @tmp
    ENV["HOME"] = @tmp
    ENV["HIVEBOX_SESSION_SECRET"] = "x" * 64
    File.write(File.join(@tmp, "config.yml"), {
      "registered_projects" => [ { "name" => "demo", "path" => @tmp } ],
      "web" => { "origin" => "http://127.0.0.1", "github" => { "owner" => "alice", "client_id" => "c" } }
    }.to_yaml)
    @saved_auth = app.settings.github_auth
    @saved_feed = app.settings.status_feed
    @saved_dispatcher = app.settings.dispatcher
    app.set :github_auth, FakeAuth.new("alice", true)
    app.set :status_feed, StubFeed.new
  end

  def teardown
    app.set :github_auth, @saved_auth
    app.set :status_feed, @saved_feed
    app.set :dispatcher, @saved_dispatcher
    @old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    FileUtils.rm_rf(@tmp)
  end

  def login!
    get "/auth/github", {}, "HTTP_HOST" => "127.0.0.1"
    state = last_response["Location"][/state=([^&]+)/, 1]
    get "/auth/github/callback", { "code" => "ok", "state" => state }, "HTTP_HOST" => "127.0.0.1"
  end

  def test_login_page_renders
    get "/login", {}, "HTTP_HOST" => "127.0.0.1"
    assert last_response.ok?
  end

  def test_auth_github_redirects_and_stores_state
    get "/auth/github", {}, "HTTP_HOST" => "127.0.0.1"
    assert last_response.redirect?
    assert_match(/state=real-state-value/, last_response["Location"])
  end

  def test_auth_github_unconfigured_500s
    app.set :github_auth, FakeAuth.new("alice", false)
    get "/auth/github", {}, "HTTP_HOST" => "127.0.0.1"
    assert_equal 500, last_response.status
  end

  def test_callback_admits_owner_and_sets_session
    login!
    assert last_response.redirect?
    assert_equal "http://127.0.0.1/", last_response["Location"]
  end

  def test_callback_rejects_absent_state
    # No /auth/github first → no stored state. nil-vs-nil must NOT pass.
    get "/auth/github/callback", { "code" => "ok" }, "HTTP_HOST" => "127.0.0.1"
    assert_equal 403, last_response.status
    assert_match(/Invalid OAuth state/, last_response.body)
  end

  def test_callback_rejects_mismatched_state
    get "/auth/github", {}, "HTTP_HOST" => "127.0.0.1"
    get "/auth/github/callback", { "code" => "ok", "state" => "forged" }, "HTTP_HOST" => "127.0.0.1"
    assert_equal 403, last_response.status
  end

  def test_callback_surfaces_denied_consent
    get "/auth/github", {}, "HTTP_HOST" => "127.0.0.1"
    state = last_response["Location"][/state=([^&]+)/, 1]
    get "/auth/github/callback",
        { "state" => state, "error" => "access_denied", "error_description" => "denied" },
        "HTTP_HOST" => "127.0.0.1"
    assert_equal 403, last_response.status
    assert_match(/sign-in failed/, last_response.body)
  end

  def test_callback_rejects_non_owner
    app.set :github_auth, FakeAuth.new("alice", true, "mallory")
    get "/auth/github", {}, "HTTP_HOST" => "127.0.0.1"
    state = last_response["Location"][/state=([^&]+)/, 1]
    get "/auth/github/callback", { "code" => "ok", "state" => state }, "HTTP_HOST" => "127.0.0.1"
    assert_equal 403, last_response.status
    assert_match(/is not allowed/, last_response.body)
  end

  def test_logout_clears_session
    login!
    token = csrf_token
    post "/logout", { "authenticity_token" => token }, "HTTP_HOST" => "127.0.0.1"
    assert last_response.redirect?
    assert_match(%r{/login\z}, last_response["Location"])
  end

  def test_unknown_project_404s_via_find_project
    login!
    get "/tasks/nope/task-a/diff", {}, "HTTP_HOST" => "127.0.0.1"
    assert_equal 404, last_response.status
    assert_includes last_response.body, "unknown project"
  end

  def test_known_project_resolves_via_find_project
    login!
    # demo/task-a resolves the project (find_project! happy path); the task
    # page renders even though the row's folder is nil.
    get "/tasks/demo/task-a", {}, "HTTP_HOST" => "127.0.0.1"
    assert last_response.ok?
  end

  def test_invalid_task_path_maps_to_404
    login!
    # A diff for an absent worktree on a real project hits find_project! +
    # safe_slug!, then halts 404 (worktree not found) — exercising the
    # validated read path.
    get "/tasks/demo/missing-slug/diff", {}, "HTTP_HOST" => "127.0.0.1"
    assert_includes [ 404 ], last_response.status
  end

  def csrf_token
    get "/", {}, "HTTP_HOST" => "127.0.0.1"
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
  end

  # The InvalidTaskPath error handler (404) must fire when a route raises it.
  # A real dispatcher approving a non-existent task raises InvalidTaskPath.
  def test_error_handler_maps_invalid_task_path_to_404
    login!
    token = csrf_token
    app.set :dispatcher, Hive::Web::Dispatcher.new
    post "/tasks/demo/missing-task-260101-aaaa/approve",
         { "from" => "2-brainstorm", "authenticity_token" => token },
         "HTTP_HOST" => "127.0.0.1"
    assert_equal 404, last_response.status, "an unknown task must hit the InvalidTaskPath 404 handler"
    assert_includes last_response.body, "Not found"
  end

  # The catch-all Hive::Error/KeyError handler (422) must fire for a genuine
  # unprocessable case — here an unknown dispatch action (KeyError).
  def test_error_handler_maps_hive_error_to_422
    login!
    token = csrf_token
    app.set :dispatcher, Hive::Web::Dispatcher.new
    post "/tasks/demo/task-a/dispatch",
         { "action" => "totally-unknown", "authenticity_token" => token },
         "HTTP_HOST" => "127.0.0.1"
    assert_equal 422, last_response.status, "an unknown action must hit the 422 handler"
    assert_includes last_response.body, "Action failed"
  end
end
