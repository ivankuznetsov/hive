require "test_helper"
require "hive/task_projection"

class TaskProjectionTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 17, 11, 0, 0)

  def test_missing_observations_are_pending_and_later_stage_vocabulary_is_inactive
    projection = Hive::TaskProjection.project(records: [], cursor: 0, journal_hash: "empty")

    assert_equal 7, projection["conditions"].fetch("current").size
    assert projection["conditions"].fetch("current").all? { |fact| fact["state"] == "pending" }
    assert_equal "reconcile_required",
                 projection["gates"].dig("execute_to_open_pr", "status")
    assert_equal 0, projection["identity"].fetch("task_generation")
  end

  def test_lifecycle_observations_round_trip_and_prior_evidence_is_retained
    states = %w[pending satisfied unsatisfied unverifiable]
    records = states.each_with_index.map do |state, index|
      condition_event(
        "AgentHealthy", state: state, event_id: "event-#{index}",
        reason: "state_#{state}", evidence: attempt_evidence(index)
      )
    end
    projection = Hive::TaskProjection.project(records: records)

    current = projection.current_condition("AgentHealthy")
    assert_equal "unverifiable", current.fetch("state")
    assert_equal "state_unverifiable", current.fetch("reason")
    history = projection["conditions"].fetch("history")
    assert_equal %w[pending satisfied unsatisfied], history.map { |fact| fact.fetch("original_state") }
    assert history.all? { |fact| fact["state"] == "superseded" }
    assert_equal %w[event-0 event-1 event-2], history.map { |fact| fact.dig("evidence", 0, "event_id") }
  end

  def test_older_task_generations_never_satisfy_current_conditions
    records = [
      condition_event("AgentHealthy", state: "satisfied", event_id: "old", task_generation: 1),
      generation_event(event_id: "generation-2", task_generation: 2)
    ]
    projection = Hive::TaskProjection.project(records: records)

    assert_equal "pending", projection.current_condition("AgentHealthy").fetch("state")
    historical = projection["conditions"].fetch("history").find { |fact| fact["event_id"] == "old" }
    assert_equal "older_task_generation", historical.fetch("superseded_reason")
  end

  def test_newer_attempt_changes_supersede_an_old_no_change_wait_across_execute_outcome_family
    records = [
      condition_event("ChangesPresent", state: "unsatisfied", event_id: "a-changes",
                      attempt_id: "attempt-a", reason: "no_worktree_changes",
                      evidence: commit_evidence("a" * 40), commit_generation: 1),
      condition_event("AwaitingHuman", state: "satisfied", event_id: "a-wait",
                      attempt_id: "attempt-a", reason: "no_worktree_changes"),
      commit_event(event_id: "head-b", attempt_id: "attempt-b", commit_generation: 2, sha: "b" * 40),
      condition_event("ChangesPresent", state: "satisfied", event_id: "b-changes",
                      attempt_id: "attempt-b", reason: "commit_present",
                      evidence: commit_evidence("b" * 40), commit_generation: 2)
    ]
    projection = Hive::TaskProjection.project(records: records)

    changes = projection.current_condition("ChangesPresent")
    wait = projection.current_condition("AwaitingHuman")
    assert_equal "attempt-b", changes.fetch("attempt_id")
    assert_equal "satisfied", changes.fetch("state")
    assert_equal "pending", wait.fetch("state")
    historical_wait = projection["conditions"].fetch("history").find { |fact| fact["event_id"] == "a-wait" }
    assert_equal "newer_incompatible_attempt", historical_wait.fetch("superseded_reason")
    assert_equal "satisfied", historical_wait.fetch("original_state")
  end

  def test_commit_scoped_facts_must_match_current_commit_generation_and_head
    records = [
      commit_event(event_id: "head-a", commit_generation: 1, sha: "a" * 40),
      condition_event("ChangesPresent", state: "satisfied", event_id: "change-a",
                      commit_generation: 1, evidence: commit_evidence("a" * 40)),
      commit_event(event_id: "head-b", commit_generation: 2, sha: "b" * 40)
    ]
    stale = Hive::TaskProjection.project(records: records)
    assert_equal "pending", stale.current_condition("ChangesPresent").fetch("state")
    assert_equal "older_commit_generation",
                 stale["conditions"].fetch("history").find { |fact| fact["event_id"] == "change-a" }
                      .fetch("superseded_reason")

    records << condition_event("ChangesPresent", state: "satisfied", event_id: "change-b",
                               commit_generation: 2, evidence: commit_evidence("b" * 40))
    current = Hive::TaskProjection.project(records: records)
    assert_equal "change-b", current.current_condition("ChangesPresent").fetch("event_id")
    assert_equal "b" * 40, current["identity"].fetch("head_sha")
  end

  def test_new_unverifiable_commit_fact_stays_current_after_a_prior_known_head
    records = [
      commit_event(event_id: "head-a", commit_generation: 1, sha: "a" * 40),
      condition_event(
        "ChangesPresent", state: "satisfied", event_id: "known-change",
        commit_generation: 1, evidence: commit_evidence("a" * 40)
      ),
      condition_event(
        "ChangesPresent", state: "unverifiable", event_id: "git-unavailable",
        attempt_id: "attempt-b", commit_generation: 1,
        reason: "worktree_evidence_unverifiable",
        evidence: [ { "type" => "journal_event", "event_id" => "git-read-failed" } ]
      )
    ]

    projection = Hive::TaskProjection.project(records: records)
    current = projection.current_condition("ChangesPresent")
    assert_equal "git-unavailable", current.fetch("event_id")
    assert_equal "unverifiable", current.fetch("state")
    assert_equal "worktree_evidence_unverifiable", current.fetch("reason")
  end

  def test_marker_fallback_is_centralized_and_disappears_after_baseline
    marker = Hive::Markers::State.new(name: :execute_complete, attrs: { "mode" => "research" }, raw: nil)
    fallback = Hive::TaskProjection.project(records: [], marker: marker)
    assert_equal "execute_complete", fallback["compatibility"].dig("marker_fallback", "name")

    baseline = generation_event(event_id: "baseline", event_type: "legacy_baseline",
                                attempt_id: "legacy", task_generation: 0)
    projected = Hive::TaskProjection.project(records: [ baseline ], marker: marker)
    assert projected["compatibility"].fetch("baseline_present")
    assert_nil projected["compatibility"].fetch("marker_fallback")
  end

  def test_duplicate_event_ids_and_malformed_journal_are_rejected
    with_tmp_dir do |dir|
      path = File.join(dir, "task-journal.jsonl")
      event = condition_event("AgentHealthy", event_id: "duplicate")
      File.write(path, "#{JSON.generate(event)}\n#{JSON.generate(event)}\n")
      assert_raises(Hive::TaskProjection::InvalidJournal) { Hive::TaskProjection.read_journal(path) }

      File.write(path, "{\n")
      assert_raises(Hive::TaskProjection::InvalidJournal) { Hive::TaskProjection.read_journal(path) }
    end
  end

  def test_snapshot_and_hash_attempt_metadata_validation_fail_closed
    assert_raises(Hive::TaskProjection::InvalidJournal) do
      Hive::TaskProjection.from_data("schema" => "wrong", "schema_version" => 1)
    end

    metadata = Hive::TaskProjection.durable_attempt_metadata(
      "attempt_id" => "attempt-a", "task_id" => "42", "task_slug" => "task",
      "intended_stage" => "4-execute", "task_input_epoch" => 3,
      "ownership_generation" => "owner-a", "accepted_at" => NOW.iso8601(6),
      "predecessor_attempt_id" => nil, "state" => "running",
      "outcome" => nil, "lease_version" => 2
    )
    assert_equal 3, metadata.fetch("task_generation")
    assert_equal "owner-a", metadata.fetch("ownership_generation")
    assert_equal 2, metadata.fetch("lease_version")
  end

  def test_causal_attempt_lookup_walks_multi_hop_predecessors
    lineage = [
      attempt_binding("attempt-a", predecessor: nil),
      attempt_binding("attempt-b", predecessor: "attempt-a"),
      attempt_binding("attempt-c", predecessor: "attempt-b")
    ]
    record = generation_event(event_id: "generation", task_generation: 1)
    record["__attempt_lineage"] = lineage
    projection = Hive::TaskProjection.new(
      records: [ record ], cursor: nil, journal_hash: nil,
      marker: nil, registry: Hive::Conditions::Registry.default
    )

    assert projection.send(:attempt_descends_from?, "attempt-c", "attempt-a")
    refute projection.send(:attempt_descends_from?, "attempt-a", "attempt-c")
  end

  def test_implementation_identity_projection_retains_generations_and_latest_stage_launches
    execute_one = event(
      event_type: "implementation_identity_captured", event_id: "identity-1",
      task_generation: 1, commit_generation: 0,
      payload: { "identity" => identity_payload("execute", "codex", "gpt-5.6-sol", 1) }
    )
    open_pr_one = event(
      event_type: "implementation_stage_resolved", event_id: "open-pr-1",
      task_generation: 1, commit_generation: 0,
      payload: { "identity" => identity_payload("open_pr", "codex", "gpt-5.6-terra", 1) }
    )
    execute_two = event(
      event_type: "implementation_identity_captured", event_id: "identity-2",
      task_generation: 2, commit_generation: 0,
      payload: { "identity" => identity_payload("execute", "claude", "claude-fable-5", 2) }
    )

    projection = Hive::TaskProjection.project(records: [ execute_one, open_pr_one, execute_two ])
    identity = projection["implementation_identity"]

    assert_equal 2, identity.fetch("generation")
    assert_equal "claude", identity.dig("execute", "provider")
    assert_equal %w[codex claude], identity.fetch("history").map { |entry| entry["provider"] }
    assert_equal({}, identity.fetch("stages"))
  end

  def test_validated_closure_overlay_preserves_condition_and_attempt_truth
    projection = Hive::TaskProjection.project(
      records: [
        condition_event(
          "AgentHealthy", state: "satisfied", event_id: "healthy",
          evidence: attempt_evidence(1)
        )
      ]
    )
    receipt = {
      "schema" => "hive-task-closure",
      "schema_version" => 1,
      "reason" => "already_delivered",
      "receipt_digest" => "d" * 64
    }

    overlaid = projection.with_closure(receipt)

    assert_nil projection.to_h["closure"], "the replay projection must remain immutable"
    assert_equal receipt, overlaid.to_h.fetch("closure")
    assert_equal projection.to_h.fetch("identity"), overlaid.to_h.fetch("identity")
    assert_equal projection.to_h.fetch("conditions"), overlaid.to_h.fetch("conditions")
  end

  private

  def condition_event(name, state: "satisfied", event_id:, attempt_id: "attempt-a",
                      task_generation: 1, commit_generation: 1, reason: "observed",
                      evidence: nil)
    definition = Hive::Conditions::Registry.default.fetch(name)
    evidence ||= definition.allowed_evidence.include?(:attempt_lease) ? attempt_evidence(1) : commit_evidence("a" * 40)
    event(
      event_type: "condition_observed", event_id: event_id, attempt_id: attempt_id,
      task_generation: task_generation, commit_generation: commit_generation,
      reason: reason, evidence: evidence, payload: { "condition" => name, "state" => state }
    )
  end

  def generation_event(event_id:, task_generation:, event_type: "generation_advanced",
                       attempt_id: "attempt-a")
    event(event_type: event_type, event_id: event_id, task_generation: task_generation,
          attempt_id: attempt_id, commit_generation: 0, reason: "input_changed")
  end

  def commit_event(event_id:, commit_generation:, sha:, attempt_id: "attempt-a")
    event(event_type: "commit_generation_advanced", event_id: event_id, attempt_id: attempt_id,
          task_generation: 1, commit_generation: commit_generation, reason: "head_changed",
          evidence: commit_evidence(sha), payload: { "head_sha" => sha, "branch" => "feature" })
  end

  def event(overrides)
    {
      "schema" => Hive::TaskJournal::Envelope::SCHEMA,
      "schema_version" => 1,
      "event_id" => "event",
      "event_type" => "reconciliation",
      "occurred_at" => NOW.iso8601(6),
      "observed_at" => NOW.iso8601(6),
      "task" => { "id" => "42", "slug" => "task" },
      "workflow" => "coding",
      "stage" => "4-execute",
      "attempt_id" => "attempt-a",
      "task_generation" => 1,
      "ownership_generation" => "owner-1",
      "commit_generation" => 1,
      "reason" => "observed",
      "evidence" => [],
      "provenance" => { "source" => "test" },
      "payload" => {}
    }.merge(overrides.transform_keys(&:to_s))
  end

  def identity_payload(stage, provider, model, generation)
    {
      "stage" => stage, "provider" => provider, "model" => model,
      "profile_name" => provider, "launcher_identity" => "#{provider}/v1",
      "source" => "persisted_execute", "generation" => generation,
      "originating_attempt" => "attempt-a", "requested_effort" => "high",
      "effective_effort" => "high", "effort_supported" => true,
      "model_pinned" => true
    }
  end

  def attempt_evidence(index)
    [ { "type" => "attempt_lease", "attempt_id" => "attempt-a",
        "lease_version" => index, "state" => "running", "event_id" => "event-#{index}" } ]
  end

  def commit_evidence(sha)
    [ { "type" => "commit", "sha" => sha, "branch" => "feature" } ]
  end

  def attempt_binding(attempt_id, predecessor:)
    {
      "attempt_id" => attempt_id,
      "task" => { "id" => "42", "slug" => "task" },
      "stage" => "4-execute",
      "task_generation" => 1,
      "ownership_generation" => "owner-#{attempt_id}",
      "accepted_at" => NOW.iso8601(6),
      "predecessor_attempt_id" => predecessor,
      "state" => "running",
      "outcome" => nil,
      "lease_version" => 1
    }
  end
end
