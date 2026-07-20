require "test_helper"
require "json_schemer"
require "hive/operational_status"

class OperationalStatusTest < Minitest::Test
  STATES = %w[
    unknown running needs_repair waiting_on_you
    waiting_on_provider_or_scheduler completion_ready idle
  ].freeze

  def test_projects_complete_graph_into_closed_operational_states_and_archive_counts
    payload = status_payload(
      task(action: "agent_running", slug: "running", live_task_lock: true, task_lock_pid: 42),
      task(action: "needs_input", slug: "question", stage: "2-brainstorm", unanswered_questions: 2),
      task(action: "ready_to_run", slug: "provider", held: {
        "reason" => "quota", "provider" => "codex", "retry_after" => "2026-07-20T12:00:00Z"
      }),
      task(action: "error", slug: "repair", marker: "error", attrs: { "reason" => "agent_died" }),
      task(action: "ready_to_archive", slug: "complete", stage: "8-finalize", marker: "complete"),
      task(action: "ready_to_plan", slug: "idle", stage: "2-brainstorm", marker: "complete"),
      task(action: "archived", slug: "archived", stage: "9-done", marker: "complete")
    )

    result = project(payload)

    assert_equal "hive-operational-status", result.fetch("schema")
    assert_equal 1, result.fetch("schema_version")
    assert_equal true, result.fetch("ok")
    assert_equal 6, result.dig("summary", "active")
    assert_equal 1, result.dig("archive", "count")
    assert_equal STATES, result.dig("summary", "states").keys
    assert_equal %w[
      running waiting_on_you waiting_on_provider_or_scheduler needs_repair completion_ready idle
    ].sort, result.fetch("tasks").map { |row| row.fetch("state") }.sort
    refute result.fetch("tasks").any? { |row| row.dig("identity", "slug") == "archived" }
  end

  def test_running_precedence_retains_provider_hold_as_secondary_reason
    row = task(
      action: "agent_running", slug: "overlap", live_task_lock: true,
      held: { "reason" => "quota", "provider" => "codex", "retry_after" => nil }
    )

    projected = project(status_payload(row)).fetch("tasks").first

    assert_equal "running", projected.fetch("state")
    assert_equal "agent", projected.fetch("blocker_owner")
    assert_includes projected.fetch("reasons").map { |reason| reason.fetch("code") }, "provider_quota"
  end

  def test_dead_recorded_runner_is_repair_not_running
    row = task(action: "agent_running", slug: "stale").merge(
      "claude_pid" => 99_999,
      "claude_pid_alive" => false
    )

    projected = project(status_payload(row)).fetch("tasks").first

    assert_equal "needs_repair", projected.fetch("state")
    assert_equal "hive", projected.fetch("blocker_owner")
    assert_equal "stale", projected.dig("liveness", "status")
    assert_equal "stale_runner", projected.dig("reasons", 0, "code")
  end

  def test_invalid_task_is_unknown_while_admission_error_needs_repair
    invalid = task(
      action: "error", slug: "invalid", marker: "error",
      attrs: { "reason" => "invalid_task", "message" => "unknown workflow" }
    )
    admission = task(
      action: "admission_error", slug: "admission", blocked: true,
      admission_error: {
        "reason_code" => "dependency_cycle", "offending_ref" => "demo:a -> demo:a",
        "safe_correction" => "Break the cycle."
      }
    )

    rows = project(status_payload(invalid, admission)).fetch("tasks").to_h do |row|
      [ row.dig("identity", "slug"), row ]
    end

    assert_equal "unknown", rows.fetch("invalid").fetch("state")
    assert_equal "needs_repair", rows.fetch("admission").fetch("state")
    assert_equal "Break the cycle.", rows.fetch("admission").fetch("reason")
  end

  def test_daemon_owned_plan_approval_is_not_reported_as_human_input
    plan = task(action: "needs_input", slug: "plan", stage: "3-plan", marker: "waiting")

    automated = project(
      status_payload(plan),
      project_context: { "demo" => { "daemon_enabled" => true } }
    ).fetch("tasks").first
    manual = project(
      status_payload(plan),
      project_context: { "demo" => { "daemon_enabled" => false } }
    ).fetch("tasks").first

    assert_equal "waiting_on_provider_or_scheduler", automated.fetch("state")
    assert_equal "scheduler", automated.fetch("blocker_owner")
    assert_equal "waiting_on_you", manual.fetch("state")
    assert_equal "operator", manual.fetch("blocker_owner")
  end

  def test_project_failures_and_invalid_rows_make_completeness_explicit
    payload = status_payload(task(action: "ready_to_plan", slug: "healthy"))
    payload.fetch("projects") << {
      "name" => "broken", "path" => "/tmp/broken", "hive_state_path" => "/tmp/broken/.hive-state",
      "error" => "project_load_failed", "tasks" => []
    }

    result = project(payload)

    assert_equal "partial", result.fetch("completeness")
    assert_equal "partial", result.dig("source", "task_graph", "status")
    assert_includes result.fetch("issues").map { |issue| issue.fetch("code") }, "project_load_failed"
    refute_equal "idle", result.dig("summary", "overall_state")
  end

  def test_empty_registry_is_complete_and_not_scheduler_degraded
    result = project(status_payload)

    assert_equal "complete", result.fetch("completeness")
    assert_equal 0, result.dig("summary", "active")
    assert_equal 0, result.dig("archive", "count")
    assert_equal "not_applicable", result.dig("scheduler", "status")
    assert_equal "idle", result.dig("summary", "overall_state")
  end

  def test_daemon_enabled_project_without_observation_is_partial_not_idle
    result = project(
      status_payload(task(action: "ready_to_plan", slug: "queued")),
      project_context: { "demo" => { "daemon_enabled" => true } }
    )

    assert_equal "partial", result.fetch("completeness")
    assert_equal "unavailable", result.dig("scheduler", "status")
    assert_equal "unknown", result.dig("summary", "overall_state")
    assert_includes result.fetch("issues").map { |issue| issue.fetch("code") }, "scheduler_unavailable"
  end

  def test_matching_complete_daemon_observation_explains_scheduler_gate
    source_task = task(action: "ready_to_plan", slug: "capacity-wait")
    snapshot = scheduler_snapshot_for(
      source_task,
      decision: "global_cap",
      reason: "global dispatch capacity is exhausted"
    )

    result = project(
      status_payload(source_task),
      project_context: { "demo" => { "daemon_enabled" => true } },
      scheduler_snapshot: snapshot
    )
    projected = result.fetch("tasks").first

    assert_equal "complete", result.fetch("completeness")
    assert_equal "waiting_on_provider_or_scheduler", projected.fetch("state")
    assert_equal "scheduler", projected.fetch("blocker_owner")
    assert_equal "global_cap", projected.dig("reasons", 0, "code")
    assert_equal "current", projected.dig("freshness", "scheduler_status")
    assert_nil projected.fetch("action"), "daemon-owned work must not offer a bypass action"
    assert_equal "daemon-generation-1", result.dig("daemon", "generation")
  end

  def test_mismatched_daemon_observation_is_warning_not_definitive_blocker
    source_task = task(action: "ready_to_plan", slug: "moved")
    snapshot = scheduler_snapshot_for(
      source_task.merge("stage" => "2-brainstorm"),
      decision: "global_cap",
      reason: "global dispatch capacity is exhausted"
    )

    result = project(
      status_payload(source_task),
      project_context: { "demo" => { "daemon_enabled" => true } },
      scheduler_snapshot: snapshot
    )
    projected = result.fetch("tasks").first

    assert_equal "partial", result.fetch("completeness")
    assert_equal "unavailable", projected.dig("freshness", "scheduler_status")
    refute_includes projected.fetch("reasons").map { |reason| reason.fetch("code") }, "global_cap"
    assert_includes result.fetch("issues").map { |issue| issue.fetch("code") }, "scheduler_task_mismatch"
  end

  def test_routine_action_is_closed_freshness_bound_and_contains_no_argv
    row = task(action: "ready_to_plan", slug: "advance", marker: "complete")
    action = project(status_payload(row)).fetch("tasks").first.fetch("action")

    assert_equal "workflow.advance", action.fetch("action_id")
    assert_equal "demo:advance", action.fetch("target")
    assert_equal false, action.fetch("confirmation_required")
    assert_equal "routine_idempotent", action.fetch("risk_class")
    assert_match(/\A[0-9a-f]{64}\z/, action.fetch("observation_token"))
    refute action.key?("argv")
    refute_includes JSON.generate(action), "hive plan"

    changed = row.merge("mtime" => "2026-07-20T10:00:01.000000Z")
    changed_action = project(status_payload(changed)).fetch("tasks").first.fetch("action")
    refute_equal action.fetch("observation_token"), changed_action.fetch("observation_token")
  end

  def test_human_and_elevated_states_have_no_executable_action
    rows = [
      task(action: "needs_input", slug: "human"),
      task(action: "error", slug: "error", marker: "error"),
      task(action: "review_parked", slug: "parked", stage: "6-review")
    ]

    project(status_payload(*rows)).fetch("tasks").each do |row|
      assert_nil row.fetch("action"), "#{row.dig('identity', 'slug')} must not be executable"
    end
  end

  def test_payload_validates_against_published_schema
    result = project(status_payload(task(action: "ready_to_plan", slug: "valid")))
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-operational-status"))))

    assert schema.valid?(result), schema.validate(result).map { |error| error.fetch("error") }.inspect
  end

  private

  def project(payload, project_context: {}, scheduler_snapshot: nil)
    Hive::OperationalStatus.new(
      status_payload: payload,
      project_context: project_context,
      scheduler_snapshot: scheduler_snapshot,
      now: Time.utc(2026, 7, 20, 10, 0, 2)
    ).to_h
  end

  def scheduler_snapshot_for(source_task, decision:, reason:)
    {
      "status" => "current",
      "phase" => "complete",
      "observed_at" => "2026-07-20T10:00:01Z",
      "valid_until" => "2026-07-20T10:01:31Z",
      "tick_sequence" => 7,
      "daemon" => {
        "generation" => "daemon-generation-1",
        "pid" => 1234,
        "process_start_time" => "process-start-1"
      },
      "capacity" => { "global" => { "used" => 2, "available" => 0 } },
      "queue" => { "pending" => 1 },
      "provider_holds" => [],
      "tasks" => [ {
        "identity" => {
          "project" => "demo", "slug" => source_task.fetch("slug"),
          "folder" => source_task.fetch("folder")
        },
        "workflow" => source_task["workflow"],
        "stage" => source_task["stage"],
        "marker" => source_task["marker"],
        "task_generation" => source_task["task_generation"],
        "condition_task_generation" => source_task["condition_task_generation"],
        "commit_generation" => source_task["commit_generation"],
        "attempt_id" => source_task["attempt_id"],
        "disposition" => {
          "status" => "available", "decision" => decision,
          "owner" => "scheduler", "reason" => reason
        }
      } ]
    }
  end

  def status_payload(*tasks)
    projects = if tasks.empty?
      []
    else
      [ {
        "name" => "demo", "path" => "/tmp/demo", "hive_state_path" => "/tmp/demo/.hive-state",
        "tasks" => tasks, "legacy_stage_dirs" => [], "legacy_migrate_command" => nil
      } ]
    end
    {
      "schema" => "hive-status", "schema_version" => 6, "ok" => true,
      "generated_at" => "2026-07-20T10:00:00Z", "projects" => projects
    }
  end

  def task(action:, slug:, stage: "1-inbox", marker: "waiting", attrs: {}, held: nil,
           live_task_lock: false, task_lock_pid: nil, unanswered_questions: 0,
           blocked: false, admission_error: nil)
    row = {
      "stage" => stage,
      "slug" => slug,
      "id" => nil,
      "display_name" => slug.capitalize,
      "workflow" => "coding",
      "depends_on" => nil,
      "blocked_by" => nil,
      "dependency_stage" => nil,
      "blocked" => blocked,
      "admission_error" => admission_error,
      "folder" => "/tmp/demo/.hive-state/stages/#{stage}/#{slug}",
      "state_file" => "/tmp/demo/.hive-state/stages/#{stage}/#{slug}/task.md",
      "worktree_path" => nil,
      "pr_url" => nil,
      "marker" => marker,
      "attrs" => attrs,
      "mtime" => "2026-07-20T10:00:00.000000Z",
      "folder_mtime" => "2026-07-20T10:00:00.000000Z",
      "age_seconds" => 2,
      "claude_pid" => nil,
      "claude_pid_alive" => nil,
      "live_task_lock" => live_task_lock,
      "attempt_id" => nil,
      "task_generation" => nil,
      "task_lock_pid" => task_lock_pid,
      "task_lock_process_start_time" => nil,
      "task_lock_id" => nil,
      "condition_task_generation" => nil,
      "commit_generation" => nil,
      "current_attempt" => nil,
      "conditions" => [],
      "condition_history" => [],
      "evidence" => [],
      "condition_overrides" => [],
      "condition_gate" => nil,
      "condition_migration" => nil,
      "condition_provenance" => {},
      "shadow_audit" => {},
      "condition_warning" => nil,
      "unanswered_questions" => unanswered_questions,
      "action" => action,
      "action_label" => action.tr("_", " "),
      "suggested_command" => "hive ignored #{slug}",
      "next_action" => nil,
      "diagnostic" => nil
    }
    row["held"] = held if held
    row
  end
end
