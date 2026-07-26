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
    assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-operational-status"),
                 result.fetch("schema_version")
    assert_equal true, result.fetch("ok")
    assert_equal 6, result.dig("summary", "active")
    assert_equal 1, result.dig("archive", "count")
    assert_equal STATES, result.dig("summary", "states").keys
    assert_equal %w[
      running waiting_on_you waiting_on_provider_or_scheduler needs_repair completion_ready idle
    ].sort, result.fetch("tasks").map { |row| row.fetch("state") }.sort
    refute result.fetch("tasks").any? { |row| row.dig("identity", "slug") == "archived" }
  end

  def test_closure_projection_advertises_operator_confirmation_and_retains_archived_receipt
    receipt = {
      "schema" => Hive::TaskClosure::SCHEMA,
      "schema_version" => 1,
      "reason" => "already_delivered",
      "authority" => "remote_merge",
      "receipt_digest" => "d" * 64,
      "evidence" => [
        {
          "repository" => "acme/app",
          "url" => "https://github.com/acme/app/pull/42",
          "oid" => "a" * 40
        }
      ]
    }
    result = project(status_payload(
      task(action: "error", slug: "candidate"),
      task(
        action: "archived", slug: "delivered", stage: "9-done",
        marker: "complete", closure: receipt
      )
    ))

    candidate = result.fetch("tasks").find do |row|
      row.dig("identity", "slug") == "candidate"
    end
    assert_equal "operator_required", candidate.dig("closure", "status")
    assert_equal "workflow.close_with_evidence",
                 candidate.dig("closure", "action", "action_id")
    assert candidate.dig("closure", "action", "confirmation_required")
    refute candidate.dig("closure", "action").key?("observation_token")

    closures = result.dig("archive", "closures")
    assert_equal 1, closures.size
    archived = closures.first
    assert_equal "delivered", archived.fetch("slug")
    assert_equal "already_delivered", archived.fetch("reason")
    assert_equal "d" * 64, archived.fetch("receipt_digest")
  end

  def test_invalid_closure_keeps_semantic_reason_null_and_exposes_quarantine
    invalid = {
      "status" => "invalid",
      "reason" => "closure receipt digest does not match",
      "quarantine_path" => "/tmp/hive/closure-quarantine/task/deadbeef.json"
    }
    result = project(status_payload(
      task(action: "error", slug: "candidate", closure: invalid)
    ))
    closure = result.fetch("tasks").first.fetch("closure")

    assert_equal "blocked", closure.fetch("status")
    assert_nil closure.fetch("reason")
    assert_equal invalid.fetch("reason"), closure.fetch("diagnostic")
    assert_equal invalid.fetch("quarantine_path"),
                 closure.fetch("quarantine_path")

    schema = JSONSchemer.schema(
      JSON.parse(
        File.read(Hive::Schemas.schema_path("hive-operational-status"))
      )
    )
    assert_empty schema.validate(result).to_a
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

  def test_daemon_owned_error_retry_is_not_reported_as_operator_repair
    error = task(
      action: "error",
      slug: "retryable",
      stage: "4-execute",
      marker: "error",
      attrs: { "reason" => "agent_preflight_failed" }
    )

    automated = project(
      status_payload(error),
      project_context: {
        "demo" => { "daemon_enabled" => true, "auto_retry_enabled" => true }
      }
    ).fetch("tasks").first
    disabled = project(
      status_payload(error),
      project_context: {
        "demo" => { "daemon_enabled" => true, "auto_retry_enabled" => false }
      }
    ).fetch("tasks").first

    assert_equal "waiting_on_provider_or_scheduler", automated.fetch("state")
    assert_equal "scheduler", automated.fetch("blocker_owner")
    assert_equal "error_retry_scheduled", automated.dig("reasons", 0, "code")
    assert_equal "needs_repair", disabled.fetch("state")
    assert_equal "operator", disabled.fetch("blocker_owner")
  end

  def test_dependency_block_is_scheduler_owned_and_primary_unless_human_input_wins
    blocked = task(
      action: "ready_to_develop", slug: "blocked", blocked: true,
      depends_on: "demo:base", blocked_by: "demo:base", dependency_stage: "7-artifacts"
    )
    human = task(
      action: "needs_input", slug: "human-blocked", blocked: true,
      blocked_by: "demo:base", unanswered_questions: 1
    )

    rows = project(status_payload(blocked, human)).fetch("tasks").to_h do |row|
      [ row.dig("identity", "slug"), row ]
    end

    assert_equal "waiting_on_provider_or_scheduler", rows.fetch("blocked").fetch("state")
    assert_equal "scheduler", rows.fetch("blocked").fetch("blocker_owner")
    assert_equal "dependency_wait", rows.fetch("blocked").dig("reasons", 0, "code")
    assert_equal "waiting_on_you", rows.fetch("human-blocked").fetch("state")
    assert_equal "human_input", rows.fetch("human-blocked").dig("reasons", 0, "code")
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

  def test_legacy_stage_issue_names_hidden_directories_and_task_counts
    payload = status_payload(task(action: "ready_to_plan", slug: "visible"))
    payload.dig("projects", 0)["legacy_stage_dirs"] = [
      { "stage_dir" => "5-implement", "task_count" => 2 },
      { "stage_dir" => "6-review", "task_count" => 1 }
    ]
    payload.dig("projects", 0)["legacy_migrate_command"] = "hive migrate demo"

    issue = project(payload).fetch("issues").find { |entry| entry.fetch("code") == "legacy_stage_dirs" }

    assert_equal "3 tasks hidden in legacy stage dirs: 5-implement (2), 6-review (1)", issue.fetch("message")
    assert_equal "hive migrate demo", issue.fetch("remediation")

    payload.dig("projects", 0)["legacy_stage_dirs"] = [
      { "stage_dir" => "5-implement", "task_count" => 1 }
    ]
    singular = project(payload).fetch("issues").find { |entry| entry.fetch("code") == "legacy_stage_dirs" }
    assert_equal "1 task hidden in legacy stage dirs: 5-implement (1)", singular.fetch("message")
  end

  def test_runner_and_condition_warning_reasons_preserve_available_evidence
    live_agent = task(action: "agent_running", slug: "live-agent").merge(
      "claude_pid" => 4242,
      "claude_pid_alive" => true
    )
    warned = task(action: "ready_to_plan", slug: "warned").merge(
      "condition_warning" => "review evidence could not be verified"
    )

    rows = project(status_payload(live_agent, warned)).fetch("tasks").to_h do |row|
      [ row.dig("identity", "slug"), row ]
    end

    assert_equal "agent process 4242 is alive", rows.fetch("live-agent").fetch("reason")
    assert_includes rows.fetch("warned").fetch("reasons").map { |reason| reason.fetch("code") },
                    "condition_warning"
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

  def test_rejects_an_unsuccessful_status_payload
    payload = status_payload
    payload["ok"] = false

    error = assert_raises(ArgumentError) { project(payload) }

    assert_equal "operational status requires a successful hive-status v7 payload", error.message
  end

  def test_rejects_an_older_status_schema
    payload = status_payload
    payload["schema_version"] = 6

    error = assert_raises(ArgumentError) { project(payload) }

    assert_equal "operational status requires a successful hive-status v7 payload", error.message
  end

  def test_noncurrent_scheduler_snapshot_propagates_its_freshness
    source_task = task(action: "ready_to_plan", slug: "stale-scheduler")
    snapshot = scheduler_snapshot_for(
      source_task,
      decision: "global_cap",
      reason: "global dispatch capacity is exhausted"
    ).merge("status" => "stale", "reason" => "observation expired")

    result = project(
      status_payload(source_task),
      project_context: { "demo" => { "daemon_enabled" => true } },
      scheduler_snapshot: snapshot
    )

    assert_equal "partial", result.fetch("completeness")
    assert_equal "stale", result.dig("tasks", 0, "freshness", "scheduler_status")
    assert_includes result.fetch("issues").map { |issue| issue.fetch("code") }, "scheduler_stale"
  end

  def test_current_scheduler_snapshot_reports_a_missing_task
    source_task = task(action: "ready_to_plan", slug: "missing-from-snapshot")
    snapshot = scheduler_snapshot_for(
      source_task,
      decision: "global_cap",
      reason: "global dispatch capacity is exhausted"
    )
    snapshot["tasks"] = []

    result = project(
      status_payload(source_task),
      project_context: { "demo" => { "daemon_enabled" => true } },
      scheduler_snapshot: snapshot
    )

    assert_equal "partial", result.fetch("completeness")
    assert_equal "unavailable", result.dig("tasks", 0, "freshness", "scheduler_status")
    assert_includes result.fetch("issues").map { |issue| issue.fetch("code") }, "scheduler_task_missing"
  end

  def test_current_scheduler_snapshot_reports_an_incomplete_disposition
    source_task = task(action: "ready_to_plan", slug: "changed-during-tick")
    snapshot = scheduler_snapshot_for(
      source_task,
      decision: "global_cap",
      reason: "global dispatch capacity is exhausted"
    )
    snapshot.dig("tasks", 0, "disposition")["status"] = "unavailable"

    result = project(
      status_payload(source_task),
      project_context: { "demo" => { "daemon_enabled" => true } },
      scheduler_snapshot: snapshot
    )

    assert_equal "partial", result.fetch("completeness")
    assert_equal "unavailable", result.dig("tasks", 0, "freshness", "scheduler_status")
    assert_includes result.fetch("issues").map { |issue| issue.fetch("code") }, "scheduler_task_changed"
  end

  def test_scheduler_match_canonicalizes_symbol_keys_inside_arrays
    source_task = task(
      action: "ready_to_plan",
      slug: "canonical-policy",
      attrs: { "policy" => [ { "provider" => "codex" } ] }
    )
    snapshot = scheduler_snapshot_for(
      source_task,
      decision: "global_cap",
      reason: "global dispatch capacity is exhausted"
    )
    snapshot.dig("tasks", 0)["marker_attrs"] = { policy: [ { provider: "codex" } ] }

    result = project(
      status_payload(source_task),
      project_context: { "demo" => { "daemon_enabled" => true } },
      scheduler_snapshot: snapshot
    )

    assert_equal "complete", result.fetch("completeness")
    assert_equal "current", result.dig("tasks", 0, "freshness", "scheduler_status")
  end

  def test_scheduler_dispositions_map_to_closed_operational_states
    expectations = {
      "provider_hold" => [ "waiting_on_provider_or_scheduler", "provider" ],
      "dispatched" => [ "waiting_on_provider_or_scheduler", "scheduler" ],
      "retry_cooldown" => [ "waiting_on_provider_or_scheduler", "scheduler" ],
      "retry_in_flight" => [ "running", "agent" ],
      "retry_safety_blocked" => [ "needs_repair", "scheduler" ],
      "wait_for_answers" => [ "waiting_on_you", "operator" ],
      "quarantined" => [ "needs_repair", "scheduler" ],
      "skip" => [ "idle", "scheduler" ]
    }

    expectations.each do |decision, (state, owner)|
      source_task = task(action: "ready_to_plan", slug: decision)
      snapshot = scheduler_snapshot_for(
        source_task,
        decision: decision,
        reason: "scheduler chose #{decision}"
      )
      projected = project(
        status_payload(source_task),
        project_context: { "demo" => { "daemon_enabled" => true } },
        scheduler_snapshot: snapshot
      ).fetch("tasks").first

      assert_equal state, projected.fetch("state"), decision
      assert_equal owner, projected.fetch("blocker_owner"), decision
    end
  end

  def test_recovery_specific_scheduler_states_have_closed_classifications
    status = Hive::OperationalStatus.new(status_payload: status_payload)

    assert_equal(
      [ "unknown", "hive" ],
      status.send(
        :classify_scheduler_disposition,
        { "decision" => "recovery_unavailable" }
      )
    )
  end

  def test_retry_projection_exposes_exact_deadline_and_safety_owner
    source_task = task(
      action: "error",
      slug: "guarded-retry",
      stage: "4-execute",
      marker: "error",
      attrs: { "reason" => "implementer_failed" }
    )
    snapshot = scheduler_snapshot_for(
      source_task,
      decision: "retry_safety_blocked",
      reason: "automatic retry is safety-blocked: worktree dirty"
    )
    snapshot.dig("tasks", 0, "disposition").merge!(
      "owner" => "operator",
      "retry_due" => true,
      "retry_at" => "2026-07-20T11:00:00.000000Z",
      "retry_safe" => false,
      "safety_reason" => "worktree dirty"
    )

    projected = project(
      status_payload(source_task),
      project_context: {
        "demo" => { "daemon_enabled" => true, "auto_retry_enabled" => true }
      },
      scheduler_snapshot: snapshot
    ).fetch("tasks").first

    assert_equal "needs_repair", projected.fetch("state")
    assert_equal "operator", projected.fetch("blocker_owner")
    assert_equal({
      "due" => true,
      "retry_at" => "2026-07-20T11:00:00.000000Z",
      "safe" => false,
      "safety_reason" => "worktree dirty"
    }, projected.fetch("retry"))
    assert_equal "blocked", projected.dig("recovery", "status")
  end

  def test_durable_recovery_receipt_projects_across_marker_clear_and_terminal
    cases = {
      "queued" => [ "error", "error", "retry_pending", "admitted" ],
      "running" => [ "agent_running", "agent_working", "retry_in_flight", "dispatched" ],
      "terminal" => [ "ready_to_plan", "complete", "attempt_terminal_replay", "terminal" ]
    }

    cases.each do |status, (action, marker, decision, phase)|
      source_task = task(
        action: action,
        slug: "recovery-#{status}",
        stage: "4-execute",
        marker: marker,
        attrs: status == "queued" ? { "reason" => "implementer_failed" } : {}
      )
      snapshot = scheduler_snapshot_for(
        source_task,
        decision: decision,
        reason: "recovery is #{status}"
      )
      snapshot.dig("tasks", 0, "disposition")["recovery"] = {
        "status" => status,
        "request_id" => "request-1",
        "attempt_id" => status == "queued" ? nil : "attempt-1",
        "phase" => phase,
        "failure_origin" => "implementer_failed",
        "next_eligible_at" => "2026-07-20T10:00:00.000000Z",
        "owner" => status == "running" ? "agent" : "scheduler",
        "reason" => nil,
        "remediation" => nil,
        "retry_count" => 1,
        "provider_hint" => nil,
        "terminal_outcome" => nil,
        "terminal_at" => nil
      }

      projected = project(
        status_payload(source_task),
        project_context: {
          "demo" => { "daemon_enabled" => true, "auto_retry_enabled" => true }
        },
        scheduler_snapshot: snapshot
      ).fetch("tasks").first

      assert_equal status, projected.dig("recovery", "status"), status
      assert_equal "request-1", projected.dig("recovery", "request_id"), status
      assert_equal phase, projected.dig("recovery", "phase"), status
    end
  end

  def test_recovery_projection_derives_running_terminal_and_provider_hint_without_a_receipt
    row = task(
      action: "error", slug: "derived-recovery", stage: "4-execute",
      marker: "error",
      attrs: {
        "reason" => "limits_reached",
        "marker_id" => "marker-1",
        "retry_after" => "2026-07-20T11:00:00Z"
      }
    )
    status = Hive::OperationalStatus.new(status_payload: status_payload(row))

    running = status.send(
      :recovery_payload, row, { "decision" => "dispatched" }, "current"
    )
    terminal = status.send(
      :recovery_payload, row,
      { "decision" => "attempt_terminal_replay" },
      "current"
    )

    assert_equal "running", running.fetch("status")
    assert_equal "terminal", terminal.fetch("status")
    assert_equal(
      {
        "retry_after" => "2026-07-20T11:00:00Z",
        "display_only" => true
      },
      running.fetch("provider_hint")
    )
  end

  def test_retry_eligibility_without_a_durable_request_does_not_claim_queued
    source_task = task(
      action: "error", slug: "eligible", stage: "4-execute",
      marker: "error", attrs: {
        "reason" => "implementer_failed", "marker_id" => "marker-1"
      }
    )
    snapshot = scheduler_snapshot_for(
      source_task,
      decision: "retry_pending",
      reason: "eligible for guarded transition"
    )

    projected = project(
      status_payload(source_task),
      project_context: {
        "demo" => { "daemon_enabled" => true, "auto_retry_enabled" => true }
      },
      scheduler_snapshot: snapshot
    ).fetch("tasks").first

    assert_nil projected.fetch("recovery")
    assert_equal "workflow.retry", projected.dig("action", "action_id")
  end

  def test_malformed_queued_projection_without_request_id_stays_actionable
    source_task = task(
      action: "error", slug: "eligible-canonical", stage: "4-execute",
      marker: "error", attrs: {
        "reason" => "implementer_failed", "marker_id" => "marker-1"
      }
    )
    snapshot = scheduler_snapshot_for(
      source_task,
      decision: "retry_pending",
      reason: "eligible for guarded transition"
    )
    snapshot.dig("tasks", 0, "disposition")["recovery"] = {
      "status" => "queued", "request_id" => nil
    }

    projected = project(
      status_payload(source_task),
      project_context: {
        "demo" => { "daemon_enabled" => true, "auto_retry_enabled" => true }
      },
      scheduler_snapshot: snapshot
    ).fetch("tasks").first

    assert_nil projected.fetch("recovery")
    assert_equal "workflow.retry", projected.dig("action", "action_id")
  end

  def test_idless_recovery_marker_projects_the_one_off_migration_blocker
    source_task = task(
      action: "error", slug: "legacy", stage: "4-execute",
      marker: "error", attrs: { "reason" => "implementer_failed", "marker_id" => nil }
    )

    projected = project(status_payload(source_task)).fetch("tasks").first

    assert_equal "blocked", projected.dig("recovery", "status")
    assert_equal "recovery_migration_required", projected.dig("recovery", "reason")
    assert_includes projected.dig("recovery", "remediation"), "hive migrate"
  end

  def test_lean_recovery_projection_only_joins_recovery_candidates
    ordinary = 20.times.map do |index|
      task(action: "ready_to_plan", slug: "ordinary-#{index}", marker: "complete")
    end
    failure = task(
      action: "error", slug: "failure", stage: "4-execute",
      marker: "error", attrs: { "reason" => "timeout", "marker_id" => "marker-1" }
    )
    snapshot_tasks = (ordinary + [ failure ]).map do |row|
      scheduler_snapshot_for(
        row, decision: row.equal?(failure) ? "retry_cooldown" : "global_cap",
        reason: "observed"
      ).fetch("tasks").first
    end
    snapshot = scheduler_snapshot_for(
      failure, decision: "retry_cooldown", reason: "observed"
    ).merge("tasks" => snapshot_tasks)
    status = Hive::OperationalStatus.new(
      status_payload: status_payload(*(ordinary + [ failure ])),
      project_context: {
        "demo" => { "daemon_enabled" => true, "auto_retry_enabled" => true }
      },
      scheduler_snapshot: snapshot
    )
    matches = 0
    original = status.method(:scheduler_task_matches?)
    status.define_singleton_method(:scheduler_task_matches?) do |observed, row|
      matches += 1
      original.call(observed, row)
    end

    rows = status.recovery_rows

    assert_equal 1, matches
    assert_equal [ "failure" ], rows.map { |row| row.dig("identity", "slug") }
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

  def test_policy_change_after_daemon_observation_invalidates_scheduler_decision
    observed = task(action: "ready_to_plan", slug: "policy-drift")
    snapshot = scheduler_snapshot_for(
      observed,
      decision: "global_cap",
      reason: "global dispatch capacity is exhausted"
    )
    current = observed.merge(
      "attrs" => { "marker_id" => "rotated" },
      "action" => "ready_to_run",
      "blocked" => true,
      "blocked_by" => "demo:base"
    )

    result = project(
      status_payload(current),
      project_context: { "demo" => { "daemon_enabled" => true } },
      scheduler_snapshot: snapshot
    )

    assert_equal "partial", result.fetch("completeness")
    assert_equal "unavailable", result.dig("tasks", 0, "freshness", "scheduler_status")
    refute_includes result.dig("tasks", 0, "reasons").map { |reason| reason.fetch("code") }, "global_cap"
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

  def test_human_and_nonrecoverable_elevated_states_have_no_action_but_error_has_retry
    rows = [
      task(action: "needs_input", slug: "human"),
      task(action: "error", slug: "error", marker: "error"),
      task(action: "review_parked", slug: "parked", stage: "6-review")
    ]

    projected = project(status_payload(*rows)).fetch("tasks").to_h do |row|
      [ row.dig("identity", "slug"), row ]
    end

    assert_nil projected.fetch("human").fetch("action")
    assert_nil projected.fetch("parked").fetch("action")
    assert_equal "workflow.retry", projected.dig("error", "action", "action_id")
    assert_equal "unavailable", projected.dig("error", "recovery", "status")
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
        "marker_attrs" => source_task["attrs"] || {},
        "task_generation" => source_task["task_generation"],
        "condition_task_generation" => source_task["condition_task_generation"],
        "commit_generation" => source_task["commit_generation"],
        "attempt_id" => source_task["attempt_id"],
        "state_file_mtime" => source_task["mtime"],
        "action" => source_task["action"],
        "depends_on" => source_task["depends_on"],
        "blocked_by" => source_task["blocked_by"],
        "dependency_stage" => source_task["dependency_stage"],
        "blocked" => source_task["blocked"] == true,
        "admission_error" => source_task["admission_error"],
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
      "schema" => "hive-status",
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
      "ok" => true,
      "generated_at" => "2026-07-20T10:00:00Z", "projects" => projects
    }
  end

  def task(action:, slug:, stage: "1-inbox", marker: "waiting", attrs: {}, held: nil,
           live_task_lock: false, task_lock_pid: nil, unanswered_questions: 0,
           blocked: false, depends_on: nil, blocked_by: nil, dependency_stage: nil,
           admission_error: nil, closure: nil)
    attrs = attrs.dup
    if Hive::Recovery.recoverable_marker?(marker) && !attrs.key?("marker_id")
      attrs["marker_id"] = "marker-#{slug}"
    end
    row = {
      "stage" => stage,
      "slug" => slug,
      "id" => nil,
      "display_name" => slug.capitalize,
      "workflow" => "coding",
      "depends_on" => depends_on,
      "blocked_by" => blocked_by,
      "dependency_stage" => dependency_stage,
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
      "closure" => closure,
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
