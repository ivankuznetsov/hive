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

  test "active final content stages follow their action" do
    stage = Hive::Workflows::Content::DESCRIPTOR.stages.find { |item| item.name == "done" }
    assert_equal :agent, stage.kind
    { "ready_to_run" => "ready", "agent_running" => "running", "error" => "attention",
      "archived" => "completed" }.each do |action, expected|
      assert_equal expected, display("workflow" => "content", "stage" => stage.dir, "action" => action).state
    end
  end

  test "capacity and recovery receipts retain distinct states" do
    assert_equal "Waiting for capacity", display("held" => "capacity").label
    { "queued" => [ "waiting", "Retry queued" ], "running" => [ "running", "Running" ],
      "blocked" => [ "attention", "Retry blocked" ], "unavailable" => [ "unknown", "Status unavailable" ] }.each do |status, expected|
      state = display("recovery" => { "status" => status })
      assert_equal expected, [ state.state, state.label ]
    end
  end

  test "completed and archived records do not become failures because telemetry is missing" do
    assert_equal "Completed", display({ "stage" => "9-done", "action" => "archived" }, fresh: false).label
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

  test "dependency waits name every unmet prerequisite without array inspection" do
    dependency = display(
      "blocked" => true,
      "depends_on" => %w[first second],
      "unmet_dependencies" => [
        { "blocked_by" => "first" }, { "blocked_by" => "second" }
      ]
    )

    assert_equal "Waiting for first and second.", dependency.detail
    refute_includes dependency.detail, "[\""
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
  test "failed edit recovery uses canonical precedence and preserves reason and time" do
    %w[cooldown queued].each do |status|
      state = display(failed_edit_attributes(status))
      assert_equal "Needs recovery", state.label
      assert_includes state.detail, "spawn failed"
      assert_includes state.detail, "2026-11-03T12:05:00Z"
    end
    assert_equal "Running", display(failed_edit_attributes("running")).label

    missing = failed_edit_attributes("cooldown").merge("answers_complete" => false, "unanswered_questions" => 1)
    assert_equal "Answer questions", display(missing).label
    assert_includes display(missing).detail, "spawn failed"

    parked = missing.merge("recovery" => missing.fetch("recovery").merge(
      "status" => "blocked", "escalation_tier" => "parked", "reason" => "deterministic_failure",
      "remediation" => "edits do not release this park; use the current workflow.retry action"
    ))
    assert_equal "Needs execution repair", display(parked).label
    assert_includes display(parked).detail, "edits do not release this park"
  end

  test "unavailable failed edit scheduling retains durable reason without promising an imminent retry" do
    attributes = failed_edit_attributes("cooldown")
    [ "stale", "unavailable" ].each do |freshness|
      attributes["recovery"]["scheduler_status"] = freshness
      state = display(attributes)
      assert_equal "Status unavailable", state.label
      assert_includes state.detail, "spawn failed"
      refute_match(/retry at/i, state.detail)
    end
    cached = display(failed_edit_attributes("cooldown"), fresh: false)
    assert_equal "Status unavailable", cached.label
    assert_includes cached.detail, "spawn failed"
  end

  test "complete brainstorm without failed evidence waits without an input or retry claim" do
    state = display("workflow" => "coding", "stage" => "2-brainstorm", "marker" => "waiting",
      "action" => "needs_input", "answers_complete" => true)
    assert_equal "Waiting", state.label
    refute_match(/answer questions|retry/i, state.detail.to_s)
    cached = display({ "workflow" => "coding", "stage" => "2-brainstorm", "marker" => "waiting",
      "action" => "needs_input", "answers_complete" => true }, fresh: false)
    assert_equal "Status unavailable", cached.label
    refute_match(/stored recovery|retry at/i, cached.detail.to_s)
  end

  test "recovery without an eligibility time reports the unknown time" do
    attributes = failed_edit_attributes("queued")
    attributes["recovery"]["next_eligible_at"] = nil
    assert_includes display(attributes).detail.downcase, "retry time unavailable"
  end

  private

  def failed_edit_attributes(status)
    {
      "workflow" => "coding", "stage" => "2-brainstorm", "marker" => "waiting",
      "action" => "needs_input", "answers_complete" => true,
      "recovery" => {
        "variant" => "failed_edit", "status" => status, "reason" => "spawn failed",
        "owner" => "scheduler", "scheduler_status" => "current",
        "next_eligible_at" => "2026-11-03T12:05:00Z"
      }
    }
  end
end
