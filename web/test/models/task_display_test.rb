require "test_helper"

class TaskDisplayTest < ActiveSupport::TestCase
  def display(attributes = {}, **options)
    attributes = attributes.merge(options.extract!(*options.keys.grep(String)))
    task = Task.new(project: Project.new("name" => "demo"), attributes: {
      "stage" => "4-execute", "action" => "ready_to_develop", "action_label" => "Ready to develop"
    }.merge(attributes))
    TaskDisplay.new(task, **options)
  end

  test "running is distinct from ready and a completed stage is not a completed task" do
    assert_equal "Running", display("action" => "agent_running").label
    assert_equal "Ready", display.label
    assert_equal "Ready to continue", display("marker" => "complete").label
    assert_equal "Ready to archive", display("stage" => "8-finalize", "action" => "ready_to_archive").label
  end

  test "terminal and archived records do not become failures because telemetry is missing" do
    assert_equal "Completed", display({ "stage" => "9-done", "action" => "error" }, fresh: false).label
    assert_equal "Archived", display({ "action" => "error" }, archived: true).label
    assert_equal "Already delivered", display({ "closure" => { "reason" => "already_delivered" } }, archived: true).label
  end

  test "stale active state never claims work is currently running" do
    assert_equal "Status unavailable", display({ "action" => "agent_running" }, fresh: false).label
  end

  test "dependency and recovery waits retain the useful reason" do
    dependency = display("blocked" => true, "blocked_by" => "task-42")
    assert_equal "Waiting on a task", dependency.label
    assert_includes dependency.detail, "task-42"
    recovery = display("action" => "recover_execute", "recovery" => {
      "status" => "cooldown", "remediation" => "Wait for the provider quota to reset."
    })
    assert_equal "Waiting to retry", recovery.label
    assert_equal "Wait for the provider quota to reset.", recovery.detail
  end

  test "input and blocked review are different states" do
    assert_equal "Needs your input", display("action" => "needs_input").label
    assert_equal "Blocked", display("action" => "plan_review_blocked").label
    assert_equal "Needs attention", display("action" => "recover_execute").label
  end

  test "invalid dependencies require attention instead of ordinary waiting" do
    state = display("action" => "admission_error", "blocked" => true, "blocked_by" => "missing-task",
      "action_label" => "Admission error",
      "admission_error" => { "safe_correction" => "Dependency task is missing; correct its reference." })
    assert_equal "attention", state.state
    assert_equal "Needs attention", state.label
    assert_equal "Dependency task is missing; correct its reference.", state.detail
  end

  test "normalized Patrol dispositions do not ask for nonexistent brainstorm input" do
    { patrol_fix_rejected: [ "paused", "Rejected" ], patrol_fix_blocked: [ "attention", "Blocked" ],
      patrol_fix_escalated: [ "attention", "Needs attention" ] }.each do |action, expected|
      state = display("action" => "needs_input", "action_label" => Hive::TaskAction::ACTIONS.fetch(action).fetch(:label))
      assert_equal expected, [ state.state, state.label ]
    end
  end

  test "running and ready work do not present a prior failure as the current explanation" do
    state = display("action" => "agent_running", "diagnostic" => { "summary" => "provider_limit (provider)" })
    assert_equal "An agent is working on this step.", state.detail
    ready = display("diagnostic" => { "summary" => "provider_limit (provider)" })
    assert_equal "Ready to develop", ready.detail
  end

  test "unknown actions are not silently reported as ready" do
    assert_equal "Status unavailable", display("action" => "future_action", "action_label" => nil).label
  end
end
