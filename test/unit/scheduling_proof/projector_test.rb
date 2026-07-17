require "test_helper"
require "hive/scheduling_proof/projector"

class SchedulingProofProjectorTest < Minitest::Test
  NOW = Time.utc(2026, 7, 17, 12, 0, 0)

  def test_projects_matching_live_attempt_as_execution
    proof = projector.project_task(
      row: row,
      attempt: attempt("running"),
      observation: observation("global_capacity"),
      enrolled: true
    )

    assert_equal "execution", proof.fetch("kind")
    assert_equal "executing", proof.fetch("reason")
    assert_equal "attempt-1", proof.dig("attempt", "id")
    assert proof.dig("capacity", "owns_slot")
    assert_equal "wait", proof.dig("action", "kind")
  end

  def test_rejects_old_generation_attempt_and_observation
    old_attempt = attempt("running").merge("task_input_epoch" => 2)
    old_observation = observation("dependency_wait").merge("task_generation" => 2)
    proof = projector.project_task(
      row: row, attempt: old_attempt, observation: old_observation, enrolled: true
    )

    assert_equal "idle", proof.fetch("kind")
    assert_equal "live_evidence_unavailable", proof.fetch("reason")
    assert_nil proof.fetch("attempt")
  end

  def test_stopped_daemon_masks_idle_reason_but_retains_prior_evidence
    proof = projector(daemon_running: false).project_task(
      row: row,
      observation: observation("provider_circuit_open"),
      enrolled: true
    )

    assert_equal "daemon_not_running", proof.fetch("reason")
    assert_equal "provider_circuit_open", proof.dig("prior", "reason")
    assert proof.dig("freshness", "stale")
    assert_equal "no_safe_action", proof.dig("action", "kind")
  end

  def test_archived_and_unenrolled_tasks_have_no_proof
    assert_nil projector.project_task(row: row.merge("stage" => "9-done"), enrolled: true)
    assert_nil projector.project_task(row: row, enrolled: false)
  end

  def test_error_and_summary_are_bounded_and_redacted
    secret = "sk-#{'a' * 90}"
    proof = projector.project_task(
      row: row.merge(
        "action" => "error",
        "diagnostic" => { "summary" => "auth failed #{secret}", "detail" => "Authorization: Bearer #{secret}" }
      ),
      observation: observation("terminal_error"), enrolled: true
    )

    assert_operator proof.fetch("summary").length, :<=, 120
    refute_includes JSON.generate(proof), secret
    assert_equal "terminal_error", proof.fetch("reason")
    assert_equal "daemon_runtime", proof.dig("error", "environment_provenance")
  end

  def test_uses_durable_dependency_fields_and_accepts_string_as_of
    string_clock_projector = Hive::SchedulingProof::Projector.new(
      as_of: NOW.iso8601, daemon_running: true,
      heartbeat_at: NOW - 5, poll_interval_sec: 30
    )
    proof = string_clock_projector.project_task(
      row: row.merge(
        "blocked" => true, "blocked_by" => "demo/prerequisite",
        "dependency_stage" => "3-plan"
      ),
      observation: observation("dependency_wait"), enrolled: true
    )

    assert_equal "demo/prerequisite", proof.dig("dependency", "blocked_by")
    assert_equal NOW.iso8601(6), proof.dig("freshness", "as_of")
  end

  private

  def projector(daemon_running: true)
    Hive::SchedulingProof::Projector.new(
      as_of: NOW, daemon_running: daemon_running,
      heartbeat_at: NOW - 5, poll_interval_sec: 30
    )
  end

  def row
    {
      "project" => "demo", "project_path" => "/demo", "slug" => "task-260717-abcd",
      "id" => 42, "workflow" => "coding", "stage" => "4-execute",
      "condition_task_generation" => 3, "action" => "needs_input",
      "action_label" => "Needs your input",
      "suggested_command" => "hive develop task-260717-abcd --from 4-execute",
      "blocked" => false, "diagnostic" => nil
    }
  end

  def attempt(state)
    {
      "attempt_id" => "attempt-1", "project" => "demo", "task_slug" => "task-260717-abcd",
      "intended_stage" => "4-execute", "task_input_epoch" => 3,
      "state" => state, "provider" => "codex", "heartbeat_at" => NOW.iso8601,
      "retry_charge" => 1
    }
  end

  def observation(reason)
    {
      "project" => "demo", "task_slug" => "task-260717-abcd", "stage" => "4-execute",
      "task_generation" => 3, "reason" => reason, "observed_at" => NOW.iso8601,
      "eligible" => false, "queue_position" => 2,
      "provider" => { "provider" => "codex", "model" => "gpt-5" },
      "action" => nil
    }
  end
end
