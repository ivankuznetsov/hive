require "test_helper"

class TaskTest < ActiveSupport::TestCase
  ProcessStatus = Data.define(:successful) do
    def success? = successful
  end

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

  test "distinguishes an unavailable project from an unknown task" do
    project = Project.new("name" => "alpha")
    snapshot = {
      "projects" => [
        { "name" => "alpha", "error" => "project_load_failed", "tasks" => [] }
      ]
    }

    error = assert_raises(Hive::Error) do
      Task.find!(project:, slug: "still-on-disk", snapshot:)
    end

    refute_instance_of Hive::InvalidTaskPath, error
    assert_match(/project alpha status is unavailable/, error.message)
    assert_match(/repair.*reload/, error.message)
  end

  test "prefers the action label when presenting task status" do
    project = Project.new("name" => "alpha")

    assert_equal "Working", Task.new(project:, attributes: { "action_label" => "Working", "marker" => "waiting" }).status_label
    assert_equal "waiting", Task.new(project:, attributes: { "marker" => "waiting" }).status_label
    assert_equal "idle", Task.new(project:, attributes: {}).status_label
  end

  test "recovery lifecycle controls action availability and truthful context" do
    project = Project.new("name" => "alpha")
    queued = Task.new(
      project:,
      attributes: {
        "action" => "error",
        "recovery" => {
          "status" => "queued",
          "request_id" => "request-1",
          "failure_origin" => "implementer_failed"
        }
      }
    )
    terminal = Task.new(
      project:,
      attributes: {
        "action" => "error",
        "recovery" => {
          "status" => "terminal",
          "attempt_id" => "attempt-1",
          "terminal_outcome" => "succeeded",
          "terminal_at" => "2026-07-25T12:00:00.000000Z"
        }
      }
    )
    fresh = Task.new(project:, attributes: { "action" => "error" })

    assert queued.recovery_action_visible?
    refute queued.recovery_action_enabled?
    assert_equal "Recovery queued", queued.recovery_primary_label
    assert_includes queued.recovery_context, "request request-1"
    assert_includes queued.recovery_context, "origin implementer_failed"

    refute terminal.recovery_action_visible?
    refute terminal.recovery_action_enabled?
    assert_equal "Completed", terminal.recovery_primary_label
    assert_includes terminal.recovery_context, "attempt attempt-1"
    assert_includes terminal.recovery_context, "succeeded"

    assert fresh.recovery_action_visible?
    assert fresh.recovery_action_enabled?
  end

  test "max pass review escalation is visible but not directly retryable" do
    folder = Pathname(Dir.mktmpdir("hive-web-review-escalation"))
    folder.join("reviews").mkpath
    folder.join("reviews/escalations-02.md").write("# Questions\n")
    task = Task.new(
      project: Project.new("name" => "alpha"),
      attributes: {
        "action" => "recover_review",
        "marker" => "review_stale",
        "attrs" => { "pass" => "2", "marker_id" => "marker-2" },
        "folder" => folder.to_s
      }
    )

    assert task.recovery_action_visible?
    refute task.recovery_action_enabled?
  ensure
    FileUtils.remove_entry(folder) if folder&.exist?
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
    media.join("demo.webm").binwrite("video")
    assert_equal media.join("demo.webm").realpath.to_s, task.media_path("demo.webm")
    assert_nil task.media_path("../outside.png")
    assert_nil task.media_path("still.rb")
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end

  test "renders verified capture-manifest artifacts as stills and videos" do
    root = Pathname(Dir.mktmpdir("hive-web-capture-model"))
    folder = root.join("task")
    media = folder.join("media")
    media.mkpath
    media.join("state.png").binwrite("png")
    media.join("demo.webm").binwrite("video")
    artifacts = %w[state.png demo.webm].map do |name|
      path = media.join(name)
      {
        "file" => name,
        "bytes" => path.size,
        "sha256" => Digest::SHA256.file(path).hexdigest
      }
    end
    media.join("capture-manifest.json").write(JSON.generate(
      "schema" => "hive-artifact-capture",
      "schema_version" => 1,
      "status" => "captured",
      "diagnostic" => nil,
      "artifacts" => artifacts
    ))
    task = Task.new(
      project: Project.new("name" => "alpha"),
      attributes: { "slug" => "ship-it-260720-abcd", "folder" => folder.to_s }
    )

    manifest = task.media_manifest

    assert_equal "captured", manifest.fetch("status")
    assert_equal %w[still video], manifest.fetch("items").map { |item| item.fetch("type") }
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

    Task::STAGE_DISPATCH_ACTIONS.each do |stage, action|
      task = Task.new(
        project: Project.new("name" => "alpha"),
        attributes: { "stage" => "#{stage}-step" }
      )
      command = Hive::TaskAction::READY_COMMANDS.fetch(action)

      assert_equal(command == "run" ? "stage" : command, task.run_verb, action)
    end
  end

  test "queues a run through the task resource instead of a web dispatcher" do
    task = Task.new(
      project: Project.new("name" => "alpha"),
      attributes: {
        "slug" => "ship-it-260720-abcd",
        "stage" => "3-plan",
        "workflow" => "coding"
      }
    )

    result = task.run!(expected_action: "ready_to_plan", expected_stage: "3-plan")

    assert_equal [ "hive", "plan", task.slug, "--project", "alpha", "--from", "3-plan" ], result[:argv]
  ensure
    FileUtils.rm_rf(File.join(Hive::Paths.state_home, "dispatch_requests"))
  end

  test "refuses a stale run form before writing to the daemon queue" do
    task = Task.new(
      project: Project.new("name" => "alpha"),
      attributes: {
        "slug" => "ship-it-260720-abcd",
        "stage" => "4-execute",
        "workflow" => "coding"
      }
    )

    queued_before = Dir[File.join(Hive::Paths.state_home, "dispatch_requests", "*")]
    error = assert_raises(Hive::Error) do
      task.run!(expected_action: "ready_to_plan", expected_stage: "3-plan")
    end

    assert_match(/state changed/, error.message)
    assert_equal queued_before, Dir[File.join(Hive::Paths.state_home, "dispatch_requests", "*")]
  end

  test "diff delegates to the typed bounded task-diff service" do
    project = Project.new(
      "name" => "alpha", "path" => "/tmp/alpha",
      "hive_state_path" => "/tmp/alpha/.hive-state"
    )
    task = Task.new(
      project: project,
      attributes: {
        "slug" => "bounded-diff-260720-abcd",
        "folder" => "/tmp/alpha/.hive-state/stages/4-execute/bounded-diff-260720-abcd"
      }
    )
    result = Hive::Web::TaskDiff::Result.new(
      state: "unavailable", sections: {}, truncated: false,
      invalid_encoding: false, reason: "worktree_unavailable",
      diagnostic: "pointer missing", next_action: "Inspect task status.",
      http_status: 409
    )
    service = Object.new
    service.define_singleton_method(:call) { result }
    options = nil
    factory = lambda do |**kwargs|
      options = kwargs
      service
    end

    actual = with_replaced_singleton_method(Hive::Web::TaskDiff, :new, factory) do
      task.diff
    end

    assert_same result, actual
    assert_same task, options.fetch(:task)
    assert_equal Task::DIFF_TIMEOUT_SEC, options.fetch(:timeout_sec)
  end
end
