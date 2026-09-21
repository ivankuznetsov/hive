require "test_helper"

class TaskPresentationTest < ActionView::TestCase
  include ApplicationHelper

  setup do
    @task_source = "active"
    @task = Task.new(project: Project.new("name" => "demo"), attributes: {
      "slug" => "article", "workflow" => "content", "stage" => "6-done", "action" => "ready_to_run"
    })
  end

  test "final agent stage retains manual run" do
    render partial: "tasks/primary_actions", locals: { task: @task, daemon_enabled: false }
    assert_select "form[action^='/tasks/demo/article/run'] button", text: "Run stage"
  end

  test "unavailable artifact evidence does not imply work never started" do
    render partial: "tasks/primary_result", locals: { result: { "primary" => nil, "warning" => "Artifact unavailable" } }
    assert_select "h2", text: /not started/, count: 0
    assert_select ".workspace-empty", text: /No document is available/
  end

  test "unavailable PR identity does not imply no PR exists" do
    render partial: "tasks/publication", locals: {
      publication: { "state" => "unavailable", "publication_state" => "worktree_unavailable", "diagnostics" => [] },
      refresh_available: false, refresh_notice: nil
    }
    assert_select ".empty-state", text: /No pull request yet/, count: 0
    assert_select ".empty-state", text: /Pull request details are unavailable/
  end

  test "stale running status renders an idle dot" do
    task = Task.new(project: @task.project, attributes: { "stage" => "4-execute", "action" => "agent_running" })
    html = status_dot(task, fresh: false)
    assert_includes html, "status-dot-idle"
    refute_includes html, "status-dot-running"
    assert_includes html, "Status unavailable"
  end
end
