require "test_helper"
require_relative "../../support/web_session_helper"
require "hive/commands/init"
require "hive/commands/new"

# Read-side route coverage (U4): the grid lists registered tasks once
# authenticated, and an unknown slug returns a 404 rather than leaking a
# stack trace.
class WebStatusRoutesTest < Minitest::Test
  include HiveTestHelper
  include WebSessionHelper

  def with_seeded_box
    with_tmp_global_config do |home|
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "grid probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        boot_web_app
        login!
        yield(project, slug, home)
      end
    end
  end

  def test_grid_lists_registered_tasks
    with_seeded_box do |project, slug, _home|
      get "/", {}, "HTTP_HOST" => "127.0.0.1"

      assert last_response.ok?, "authenticated GET / should render the grid"
      assert_includes last_response.body, project
      assert_includes last_response.body, slug
    end
  end

  def test_unknown_slug_returns_404
    with_seeded_box do |project, _slug, _home|
      get "/tasks/#{project}/does-not-exist", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 404, last_response.status
      refute_match(/Traceback|NoMethodError|undefined method/, last_response.body)
    end
  end

  def test_unauthenticated_grid_redirects_to_login
    with_seeded_box do |_project, _slug, _home|
      clear_cookies
      get "/", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 302, last_response.status
      assert_match(%r{/login\z}, last_response["Location"])
    end
  end

  def test_diff_returns_404_when_worktree_missing
    with_seeded_box do |project, slug, _home|
      get "/tasks/#{project}/#{slug}/diff", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 404, last_response.status, "no worktree on disk for a 1-inbox task → 404"
      assert_includes last_response.body, "worktree not found"
    end
  end

  def test_diff_rejects_malformed_slug_before_filesystem_access
    with_seeded_box do |project, _slug, _home|
      # A dotted slug isn't a valid task-folder name; safe_slug! must halt
      # before any File.join/git runs (path-traversal guard).
      get "/tasks/#{project}/has.dots/diff", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 404, last_response.status
      assert_includes last_response.body, "unknown task"
    end
  end

  def test_logs_rejects_malformed_slug
    with_seeded_box do |project, _slug, _home|
      get "/tasks/#{project}/has.dots/logs", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 404, last_response.status
      assert_includes last_response.body, "unknown task"
    end
  end
end
