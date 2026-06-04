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
end
