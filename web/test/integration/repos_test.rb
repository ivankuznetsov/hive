require "test_helper"

class ReposTest < ActionDispatch::IntegrationTest
  setup do
    @project = create_hive_project!
  end

  test "repos page lists registered projects without a github token" do
    sign_in!
    get "/repos"
    assert_response :success
    assert_match @project, response.body
    assert_match "Sign in again to grant repository access", response.body
  end

  test "github listing degrades to an inline error on a bad token" do
    # A real HTTPS round-trip to api.github.com with a junk token → 401 →
    # the page must still render the registered list with a notice, never
    # a blank 500. (Skipped automatically is NOT allowed by the house
    # rules; if GitHub is unreachable the network-error branch renders the
    # same inline notice, so the assertion holds either way.)
    sign_in!(token: "gho_definitely_invalid")
    get "/repos"
    assert_response :success
    assert_match @project, response.body, "the registered list must survive a GitHub failure"
    assert_select ".flash-alert", { minimum: 1 }, "the GitHub failure must surface inline"
  end

  test "clone rejects non-github and dash-leading urls" do
    sign_in!
    post "/repos", params: { url: "https://evil.example/x/y" }
    assert_response :unprocessable_entity

    post "/repos", params: { url: "--upload-pack=/bin/sh" }
    assert_response :unprocessable_entity
    assert_match "invalid repo URL", response.body
  end

  test "an existing directory is re-inited without cloning" do
    sign_in!
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos-root", "already-here")
    FileUtils.mkdir_p(dir)
    system("git", "init", "-q", dir, exception: true)
    File.write(File.join(dir, "README.md"), "x")
    system("git", "-C", dir, "add", ".", exception: true)
    system("git", "-C", dir, "-c", "user.email=t@e.c", "-c", "user.name=T", "commit", "-qm", "i", exception: true)

    with_repos_root(File.dirname(dir)) do
      post "/repos", params: { url: "ivankuznetsov/already-here", name: "already-here" }
    end

    assert_redirected_to "/repos"
    names = Hive::Config.registered_projects.map { |p| p["name"] }
    assert_includes names, "already-here", "the existing checkout must be registered via hive init"
  end

  private

  def with_repos_root(root)
    old = ENV["HIVEBOX_REPOS_DIR"]
    ENV["HIVEBOX_REPOS_DIR"] = root
    yield
  ensure
    old.nil? ? ENV.delete("HIVEBOX_REPOS_DIR") : ENV["HIVEBOX_REPOS_DIR"] = old
  end
end
