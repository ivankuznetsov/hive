require "test_helper"
require_relative "../../support/web_session_helper"
require "hive/commands/init"
require "hive/commands/new"

# Act-side route coverage (U5): approve/reject/intervene POSTs require a valid
# CSRF token and route through the dispatcher. These tests assert the HTTP
# wiring + CSRF gate; the dispatcher's gate logic itself is covered in
# dispatcher_test.rb.
class WebActionsTest < Minitest::Test
  include HiveTestHelper
  include WebSessionHelper

  def with_task_at(stage)
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "actions probe").call }
        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(inbox)
        dest = File.join(dir, ".hive-state", "stages", stage, slug)
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.mv(inbox, dest)
        boot_web_app
        login!
        yield(project, slug, dir, dest)
      end
    end
  end

  def test_approve_advances_task_and_redirects_home
    with_task_at("2-brainstorm") do |project, slug, dir, _folder|
      token = csrf_token_from("/tasks/#{project}/#{slug}")

      # `force=1` makes this a deterministic forward move regardless of stage
      # markers, so the test exercises the approve success path (redirect home)
      # without depending on PR/marker state.
      post "/tasks/#{project}/#{slug}/approve",
           { "from" => "2-brainstorm", "force" => "1", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert last_response.redirect?, "a successful approve redirects home (status #{last_response.status})"
      assert_equal "http://127.0.0.1/", last_response["Location"]
      assert File.directory?(File.join(dir, ".hive-state", "stages", "3-plan", slug)),
             "approve must advance the task to the next gate"
    end
  end

  def test_reject_routes_to_prior_gate
    with_task_at("6-review") do |project, slug, dir, _folder|
      token = csrf_token_from("/tasks/#{project}/#{slug}")

      post "/tasks/#{project}/#{slug}/reject",
           { "from" => "6-review", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert last_response.redirect?
      assert File.directory?(File.join(dir, ".hive-state", "stages", "5-open-pr", slug)),
             "reject POST must move the task back to its prior gate"
    end
  end

  def test_state_changing_post_without_csrf_is_rejected
    with_task_at("6-review") do |project, slug, dir, _folder|
      post "/tasks/#{project}/#{slug}/reject",
           { "from" => "6-review" },
           "HTTP_HOST" => "127.0.0.1"

      assert_equal 403, last_response.status, "missing CSRF token must be rejected"
      assert File.directory?(File.join(dir, ".hive-state", "stages", "6-review", slug)),
             "a CSRF-rejected reject must not move the task"
    end
  end

  def test_intervene_writes_into_brainstorm_file
    with_task_at("2-brainstorm") do |project, slug, _dir, folder|
      File.write(File.join(folder, "brainstorm.md"), "### Q1. Goal?\n\n### A1.\n\n")
      token = csrf_token_from("/tasks/#{project}/#{slug}")

      post "/tasks/#{project}/#{slug}/intervene",
           { "message" => "go ahead", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert last_response.redirect?
      assert_includes File.read(File.join(folder, "brainstorm.md")), "go ahead",
                      "intervene POST must persist the message into brainstorm.md"
    end
  end

  # P2: mutating routes must validate project + slug (like the read routes)
  # instead of forwarding raw params straight to the dispatcher. An unknown
  # project returns a clean 404.
  def test_approve_rejects_unknown_project_with_404
    with_task_at("6-review") do |project, slug, dir, _folder|
      token = csrf_token_from("/tasks/#{project}/#{slug}")

      post "/tasks/no-such-project/#{slug}/approve",
           { "from" => "6-review", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert_equal 404, last_response.status, "an unknown project must 404, not dispatch"
      assert File.directory?(File.join(dir, ".hive-state", "stages", "6-review", slug)),
             "a rejected approve must not move the task"
    end
  end

  def test_dispatch_rejects_malformed_slug_with_404
    with_task_at("5-open-pr") do |project, _slug, _dir, _folder|
      token = csrf_token_from("/")

      post "/tasks/#{project}/has.dots/dispatch",
           { "action" => "ready_for_review", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert_equal 404, last_response.status, "a path-traversal-ish slug must 404 before dispatch"
      assert_includes last_response.body, "unknown task"
    end
  end

  # P2: an unknown dispatch action must yield a clean 422 (via the Hive::Error
  # handler), never a queued bad verb or an opaque 500.
  def test_dispatch_unknown_action_yields_422
    with_task_at("5-open-pr") do |project, slug, _dir, _folder|
      token = csrf_token_from("/tasks/#{project}/#{slug}")

      post "/tasks/#{project}/#{slug}/dispatch",
           { "action" => "ready_to_teleport", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert_equal 422, last_response.status, "an unknown action must be a 422, not a 500 or a queued bad verb"
    end
  end

  # P2/F5: a well-formed but non-existent task slug makes approve raise
  # Hive::InvalidTaskPath (not found) — the error handler must map THAT to a
  # 404, while a genuinely unprocessable action stays 422 (covered above).
  def test_approve_of_missing_task_is_404_not_422
    with_task_at("6-review") do |project, _slug, _dir, _folder|
      token = csrf_token_from("/")
      ghost = "ghost-task-260101-aaaa"

      post "/tasks/#{project}/#{ghost}/approve",
           { "from" => "6-review", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert_equal 404, last_response.status,
                   "an unknown task (InvalidTaskPath) must be 404, not the catch-all 422"
    end
  end

  # P2: the new-idea route must also validate its project (it forwarded a raw
  # param straight to the dispatcher before). A known project routes through
  # the dispatcher; an unknown one 404s.
  def test_ideas_creates_for_known_project_and_404s_unknown
    with_task_at("2-brainstorm") do |project, _slug, dir, _folder|
      token = csrf_token_from("/")

      post "/ideas",
           { "project" => project, "text" => "a fresh idea", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"
      assert last_response.redirect?, "a known-project idea must be accepted and redirect"
      assert_equal "http://127.0.0.1/", last_response["Location"]
      assert Dir.exist?(File.join(dir, ".hive-state", "stages", "1-inbox")),
             "the new idea seeds an inbox task"

      post "/ideas",
           { "project" => "ghost-project", "text" => "nope", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"
      assert_equal 404, last_response.status, "an unknown project must 404 before dispatching"
    end
  end

  # P2: the post-dispatch redirect must be built from validated, URI-encoded
  # values so it can't be steered into a foreign Location (open redirect).
  def test_dispatch_redirect_targets_validated_task_path
    with_task_at("5-open-pr") do |project, slug, _dir, _folder|
      token = csrf_token_from("/tasks/#{project}/#{slug}")

      post "/tasks/#{project}/#{slug}/dispatch",
           { "action" => "ready_for_review", "from" => "5-open-pr", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert last_response.redirect?
      assert_equal "http://127.0.0.1/tasks/#{project}/#{slug}", last_response["Location"],
                   "the redirect must point at the validated task path, nothing else"
    end
  end
end
