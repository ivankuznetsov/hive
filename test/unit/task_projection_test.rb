require "test_helper"
require "hive/task_projection"

class TaskProjectionTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 17, 11, 0, 0)

  def test_missing_observations_are_pending_and_later_stage_vocabulary_is_inactive
    projection = Hive::TaskProjection.project(records: [], cursor: 0, journal_hash: "empty")

    assert_equal 8, projection["conditions"].fetch("current").size
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
      path = File.join(dir, "events.jsonl")
      event = condition_event("AgentHealthy", event_id: "duplicate")
      File.write(path, "#{JSON.generate(event)}\n#{JSON.generate(event)}\n")
      assert_raises(Hive::TaskProjection::InvalidJournal) { Hive::TaskProjection.read_journal(path) }

      File.write(path, "{\n")
      assert_raises(Hive::TaskProjection::InvalidJournal) { Hive::TaskProjection.read_journal(path) }
    end
  end

  def test_finalization_projection_and_archive_ready_condition_rebuild_from_journal
    records = [
      finalization_event("finalized"),
      finalization_event("merged", event_id: "merged", producer: {
                           "kind" => "babysitter_job", "job_id" => "job-1", "claim_fence" => 2
                         }, payload: finalization_coordinates.merge("merged_at" => NOW.iso8601)),
      finalization_event("archive_ready", event_id: "archive", producer: {
                           "kind" => "reconciler", "name" => "hive-finalization-reconciler-v1"
                         }, payload: finalization_coordinates.merge("terminal_event_id" => "merged"))
    ]
    projection = Hive::TaskProjection.project(records: records)

    assert_equal "archive_ready", projection["finalization"].fetch("state")
    assert_equal "satisfied", projection.current_condition("ArchiveReady").fetch("state")
    assert_equal "eligible", projection["gates"].dig("finalize_to_archive", "status")
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

  def attempt_evidence(index)
    [ { "type" => "attempt_lease", "attempt_id" => "attempt-a",
        "lease_version" => index, "state" => "running", "event_id" => "event-#{index}" } ]
  end

  def commit_evidence(sha)
    [ { "type" => "commit", "sha" => sha, "branch" => "feature" } ]
  end

  def finalization_event(type, event_id: type, producer: nil, payload: finalization_coordinates)
    event(
      event_type: type,
      event_id: event_id,
      stage: "8-finalize",
      task_generation: 3,
      attempt_id: "finalize-attempt",
      commit_generation: nil,
      reason: type,
      producer: producer || { "kind" => "finalize_attempt", "attempt_id" => "finalize-attempt" },
      payload: payload
    )
  end

  def finalization_coordinates
    {
      "job_id" => "job-1", "repository" => "github.com/acme/demo", "pr_number" => 12,
      "pr_url" => "https://github.com/acme/demo/pull/12", "head_sha" => "a" * 40,
      "head_generation" => 1, "finalize_attempt_id" => "finalize-attempt"
    }
  end
end
