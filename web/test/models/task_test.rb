require "test_helper"

class TaskTest < ActiveSupport::TestCase
  test "finds the task in its project snapshot" do
    project = Project.new("name" => "alpha", "path" => "/tmp/alpha", "hive_state_path" => "/tmp/alpha/.hive-state")
    attributes = { "slug" => "ship-it-260720-abcd", "stage" => "3-plan" }
    snapshot = {
      "projects" => [
        { "name" => "other", "tasks" => [ attributes ] },
        { "name" => "alpha", "tasks" => [ attributes ] }
      ]
    }

    task = Task.find!(project:, slug: attributes["slug"], snapshot:)

    assert_equal "3-plan", task["stage"]
    assert_equal attributes["slug"], task.slug
  end

  test "raises the typed not-found error for an unknown task" do
    error = assert_raises(Hive::InvalidTaskPath) do
      Task.find!(project: Project.new("name" => "alpha"), slug: "missing", snapshot: { "projects" => [] })
    end

    assert_equal "unknown task missing", error.message
  end

  test "resolves only plain media filenames inside the real task folder" do
    root = Pathname(Dir.mktmpdir("hive-web-task-model"))
    folder = root.join("task")
    media = folder.join("media")
    media.mkpath
    media.join("still.png").binwrite("png")
    root.join("outside.png").binwrite("outside")
    task = Task.new(
      project: Project.new("name" => "alpha"),
      attributes: { "slug" => "ship-it-260720-abcd", "folder" => folder.to_s }
    )

    assert_equal media.join("still.png").realpath.to_s, task.media_path("still.png")
    assert_nil task.media_path("../outside.png")
    assert_nil task.media_path("still.rb")
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end

  test "derives its display title from the original idea before the slug" do
    folder = Pathname(Dir.mktmpdir("hive-web-task-title"))
    folder.join("idea.md").write(<<~MARKDOWN)
      ---
      created_at: 2026-07-20 12:00:00 Z
      original_text: "Ship [image1] the calmer task page"
      ---
    MARKDOWN
    task = Task.new(
      project: Project.new("name" => "alpha"),
      attributes: { "slug" => "fallback-title-260720-abcd", "folder" => folder.to_s }
    )

    assert_equal "Ship  the calmer task page", task.title
    assert_equal "Ship [image1] the calmer task page", task.original_idea_text
  ensure
    FileUtils.remove_entry(folder) if folder&.exist?
  end

  test "maps coding and generic stages to their actual dispatch actions" do
    coding = Task.new(
      project: Project.new("name" => "alpha"),
      attributes: { "stage" => "2-brainstorm" }
    )
    generic = Task.new(
      project: Project.new("name" => "alpha"),
      attributes: {
        "stage" => "2-research", "workflow" => "content_fixture", "action" => "ready_to_run"
      }
    )
    advancing = Task.new(
      project: Project.new("name" => "alpha"),
      attributes: {
        "stage" => "2-research", "workflow" => "content_fixture", "action" => "ready_to_advance"
      }
    )

    assert_equal "ready_to_brainstorm", coding.dispatch_action
    assert_equal "brainstorm", coding.run_verb
    assert_equal "ready_to_run", generic.dispatch_action
    assert_equal "stage", generic.run_verb
    assert_nil advancing.dispatch_action
    assert_nil advancing.run_verb
  end

  test "refuses a diff when the task has no materialized worktree" do
    task = Task.new(
      project: Project.new("name" => "alpha"),
      attributes: { "slug" => "no-worktree-260720-abcd" }
    )

    error = assert_raises(Hive::InvalidTaskPath) { task.diff }

    assert_equal "no worktree for no-worktree-260720-abcd", error.message
  end
end
