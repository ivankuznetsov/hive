require "test_helper"
require "open3"

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

  test "the setup form renders the init questionnaire" do
    sign_in!
    get "/repos/new", params: { url: "ivankuznetsov/some-repo" }

    assert_response :success
    assert_select "select[name='settings[planning_agent]']", 1
    assert_select "input[name='settings[enabled_reviewers][]']", { minimum: 2 },
                  "the reviewer multi-select must offer the same set the TTY prompt does"
    assert_select "input[name='settings[budgets][brainstorm]']", 1
  end

  test "chosen settings reach hive init through the prompts seam" do
    sign_in!
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos-root2", "configured-app")
    FileUtils.mkdir_p(dir)
    system("git", "init", "-q", dir, exception: true)
    system("git", "-C", dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", dir, "config", "user.name", "Hive Test", exception: true)
    File.write(File.join(dir, "README.md"), "x")
    system("git", "-C", dir, "add", ".", exception: true)
    system("git", "-C", dir, "-c", "user.email=t@e.c", "-c", "user.name=T", "commit", "-qm", "i", exception: true)

    with_repos_root(File.dirname(dir)) do
      post "/repos", params: {
        url: "ivankuznetsov/configured-app", name: "configured-app",
        settings: {
          claude_mode: "headless", triage_bias: "safetyist", patrol_mode: "off",
          enabled_reviewers_submitted: "1", enabled_reviewers: [ "claude-ce-code-review" ],
          daemon_enabled: "0", babysitter_enabled: "0",
          budgets: { brainstorm: "3" }
        }
      }
    end

    assert_redirected_to "/repos"
    config = File.read(File.join(dir, ".hive-state", "config.yml"))
    assert_match(/headless/, config, "the chosen claude mode must land in the project config")
    assert_match(/safetyist/, config, "the chosen triage bias must land in the project config")
  end

  test "an out-of-range setting is a readable 422, not a silent default" do
    sign_in!
    post "/repos", params: { url: "ivankuznetsov/x", settings: { claude_mode: "yolo" } }

    assert_response :unprocessable_entity
    assert_match "claude_mode must be one of", response.body
  end

  test "an existing directory is re-inited without cloning" do
    sign_in!
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos-root", "already-here")
    FileUtils.mkdir_p(dir)
    system("git", "init", "-q", dir, exception: true)
    system("git", "-C", dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", dir, "config", "user.name", "Hive Test", exception: true)
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

  test "a stray file at the clone target is a 422 and survives untouched" do
    sign_in!
    root = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos-root4")
    FileUtils.mkdir_p(root)
    stray = File.join(root, "stray-name")
    File.write(stray, "operator data, not ours to delete")

    with_repos_root(root) do
      post "/repos", params: { url: "ivankuznetsov/stray-name", name: "stray-name" }
    end

    assert_response :unprocessable_entity
    assert_match "not a directory", response.body
    assert_equal "operator data, not ours to delete", File.read(stray),
                 "the pre-existing file must survive the rejected clone"
  end

  test "registration rewrites a github ssh origin to https" do
    # gh clones over ssh when the operator's git_protocol prefers it, but the
    # box can only push https (no SSH keys in the container, no agent for a
    # headless daemon) — an ssh origin means every 5-open-pr push fails.
    sign_in!
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos-root3", "ssh-origin")
    FileUtils.mkdir_p(dir)
    system("git", "init", "-q", dir, exception: true)
    system("git", "-C", dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", dir, "config", "user.name", "Hive Test", exception: true)
    File.write(File.join(dir, "README.md"), "x")
    system("git", "-C", dir, "add", ".", exception: true)
    system("git", "-C", dir, "-c", "user.email=t@e.c", "-c", "user.name=T", "commit", "-qm", "i", exception: true)
    system("git", "-C", dir, "remote", "add", "origin",
           "git@github.com:ivankuznetsov/ssh-origin.git", exception: true)

    with_repos_root(File.dirname(dir)) do
      post "/repos", params: { url: "ivankuznetsov/ssh-origin", name: "ssh-origin" }
    end

    assert_redirected_to "/repos"
    origin, = Open3.capture2("git", "-C", dir, "remote", "get-url", "origin")
    assert_equal "https://github.com/ivankuznetsov/ssh-origin.git", origin.strip,
                 "the ssh origin must be rewritten to https so the daemon can push"
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
