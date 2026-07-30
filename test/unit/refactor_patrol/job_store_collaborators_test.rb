require "digest"
require_relative "../../test_helper"
require "hive/refactor_patrol/job_store"

class RefactorPatrolJobStoreCollaboratorsTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 12, 10, 0, 0)

  def test_record_validator_preserves_job_schema_and_transition_errors
    validator = Hive::RefactorPatrol::JobRecordValidator.new(
      contract: Hive::RefactorPatrol::JobStore
    )
    aggregate = valid_job

    assert_same aggregate, validator.validate_job!(aggregate, path: "/tmp/job.json")
    assert_equal "job-1", validator.validate_id!("job-1")

    replacement = deep_copy(aggregate)
    replacement["source"]["merge_sha"] = "changed"
    error = assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.validate_transition!(aggregate, replacement, "/tmp/job.json")
    end
    assert_match "job source is immutable", error.message

    aggregate["unknown"] = true
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.validate_job!(aggregate, path: "/tmp/job.json")
    end
  end

  def test_record_validator_rejects_every_extracted_scalar_and_collection_boundary
    cases = [
      mutate_job(valid_job) { |job| job["job_id"] = "../bad" },
      mutate_job(valid_job) { |job| job["complete"] = "false" },
      mutate_job(valid_job) { |job| job["source"] = [] },
      mutate_job(valid_job) { |job| job.fetch("source").delete("url") },
      mutate_job(valid_job) { |job| job.dig("source")["number"] = 0 },
      mutate_job(valid_job) { |job| job["attempts"] = [ nil ] },
      mutate_job(valid_job) do |job|
        job["feature_results"] = [
          { "feature_id" => "feature-1", "complete" => "yes", "thesis_ids" => [], "errors" => [] }
        ]
      end,
      mutate_job(valid_job.merge("policy" => action_policy)) do |job|
        job.dig("policy", "action", "caps")["single_feature_only"] = "yes"
      end,
      mutate_job(accepted_job) do |job|
        job.dig("dispositions", "accepted", 0)["admissible"] = "yes"
      end,
      mutate_job(accepted_job) { |job| job.dig("actions", 0)["terminal"] = "yes" }
    ]

    cases.each do |invalid|
      assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord,
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        validator.validate_job!(invalid, path: "/tmp/job.json")
      end
    end
  end

  def test_record_validator_rejects_claim_generation_and_terminal_activity
    unsorted = accepted_job
    unsorted.dig("actions", 0)["claims"] = [ action_claim(2, "released"), action_claim(1, "released") ]
    error = assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.validate_job!(unsorted, path: "/tmp/job.json")
    end
    assert_match(/strictly increasing/, error.message)

    terminal = accepted_job
    terminal["state"] = "complete"
    terminal["complete"] = true
    terminal.dig("actions", 0)["terminal"] = true
    terminal.dig("actions", 0)["outcome"] = "complete"
    terminal.dig("actions", 0)["claims"] = [ action_claim(1, "claimed") ]
    error = assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.validate_job!(terminal, path: "/tmp/job.json")
    end
    assert_match(/terminal action cannot retain an active claim/, error.message)
  end

  def test_record_validator_rejects_a_gap_in_diagnostic_retry_episodes
    aggregate = accepted_job
    transition = effect_transition.merge("generation" => 2)
    aggregate["attempts"] = [
      diagnostic_attempt(aggregate.fetch("occurrence_id"), transition)
        .merge("generation" => 2)
    ]

    error = assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.validate_job!(aggregate, path: "/tmp/job.json")
    end

    assert_match(/diagnostic retry episodes must be contiguous/, error.message)
  end

  def test_record_validator_covers_publication_identity_phase_and_supersession_guards
    wrong_kind = publication_job
    wrong_kind.dig("actions", 0)["kind"] = "issue"
    assert_invalid_job(wrong_kind, /publication attempts require a fix action/)

    invalid_id = publication_job
    attempts = invalid_id.dig("actions", 0, "receipts", "publication_attempts")
    attempt = attempts.delete(attempts.keys.first)
    attempts["bad"] = attempt
    assert_invalid_job(invalid_id, /publication attempt id is invalid/)

    invalid_base = publication_job
    receipts = invalid_base.dig("actions", 0, "receipts")
    old_id, attempt = receipts.fetch("publication_attempts").first
    bad_id = Hive::RefactorPatrol::PublicationAttempt.id_for(
      publication_base_sha: "bad", commit_sha: attempt.dig("descriptor", "commit_sha")
    )
    receipts.fetch("publication_attempts").delete(old_id)
    attempt.fetch("descriptor")["attempt_id"] = bad_id
    attempt.fetch("descriptor")["publication_base_sha"] = "bad"
    receipts.fetch("patch")["publication_base_sha"] = "bad"
    receipts.fetch("publication_attempts")[bad_id] = attempt
    assert_invalid_job(invalid_base, /publication attempt publication_base_sha is invalid/)

    invalid_supersession = publication_job
    invalid_supersession.dig("actions", 0, "receipts", "publication_attempts").values.first["superseded"] = {
      "reason" => "other", "observed_head_sha" => "c" * 40, "recorded_at" => T0.iso8601
    }
    assert_invalid_job(invalid_supersession, /publication supersession evidence is invalid/)

    invalid_expected_oid = publication_job
    append_publication_phase!(
      invalid_expected_oid, "push_intent",
      publication_payload("push_intent").merge("expected_remote_oid" => "bad")
    )
    assert_invalid_job(invalid_expected_oid, /expected remote OID is invalid/)

    invalid_remote_oid = publication_job
    append_publication_phase!(invalid_remote_oid, "push_complete", publication_payload("push_complete").merge(
      "remote_oid" => "c" * 40
    ))
    assert_invalid_job(invalid_remote_oid, /remote OID is invalid/)
  end

  def test_record_validator_covers_append_only_publication_and_claim_transition_guards
    path = "/tmp/job.json"
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(:validate_publication_attempt_transition!, [], {}, path)
    end
    old = { "attempt" => { "descriptor" => {} } }
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(:validate_publication_attempt_transition!, old, {}, path)
    end
    superseded = { "attempt" => { "descriptor" => {}, "superseded" => {} } }
    changed_superseded = deep_copy(superseded)
    changed_superseded.fetch("attempt")["push_intent"] = {}
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(
        :validate_publication_attempt_transition!, superseded, changed_superseded, path
      )
    end
    active = { "attempt" => { "descriptor" => {} } }
    mixed_append = deep_copy(active)
    mixed_append.fetch("attempt").merge!("superseded" => {}, "push_intent" => {})
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(:validate_publication_attempt_transition!, active, mixed_append, path)
    end

    old_claim = action_claim(1, "claimed")
    changed_claim = deep_copy(old_claim).merge("owner" => "other")
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(:validate_active_claim_transition!, old_claim, changed_claim, path)
    end
  end

  def test_record_validator_rejects_every_v3_recovery_identity_and_history_drift
    path = "/tmp/job.json"
    occurrence_id = valid_job.fetch("occurrence_id")
    transition = effect_transition
    diagnostic = diagnostic_attempt(occurrence_id, transition)
    job_transition = job_transition_attempt(occurrence_id, transition)
    discovery = discovery_attempt(occurrence_id, transition)

    assert_invalid_attempt(
      diagnostic.merge("generation" => 0), occurrence_id, path
    )
    assert_invalid_attempt(
      diagnostic.merge("occurrence_id" => "occ-#{'f' * 64}"),
      occurrence_id,
      path
    )
    assert_invalid_attempt(
      diagnostic.merge("state" => "complete"), occurrence_id, path
    )
    assert_invalid_attempt(
      diagnostic.merge("evidence" => []), occurrence_id, path
    )
    assert_invalid_attempt(
      diagnostic.merge("action_claim_generations" => { "action-1" => -1 }),
      occurrence_id,
      path
    )
    assert_invalid_attempt(
      job_transition.merge("generation" => 0), occurrence_id, path
    )
    assert_invalid_attempt(
      job_transition.merge("occurrence_id" => "occ-#{'f' * 64}"),
      occurrence_id,
      path
    )
    assert_invalid_attempt(
      discovery.merge("occurrence_id" => "occ-#{'f' * 64}"),
      occurrence_id,
      path
    )
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(
        :validate_discovery_attempts!,
        [
          diagnostic,
          diagnostic.merge("generation" => 3)
        ],
        path,
        occurrence_id: occurrence_id
      )
    end

    invalid_transitions = [
      transition.merge("generation" => 0),
      transition.merge("semantic_digest" => "bad"),
      transition.merge("outcome" => "unknown"),
      transition.merge("error_code" => "unexpected")
    ]
    invalid_transitions.each do |invalid|
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        validator.send(
          :validate_transition_records!, [ invalid ], path, generation: 1
        )
      end
    end
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(
        :validate_transition_records!, [ transition, transition ], path,
        generation: 1
      )
    end
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(
        :validate_transition_records!,
        Array.new(
          Hive::RefactorPatrol::JobStore::MAX_TRANSITIONS_PER_GENERATION + 1,
          transition
        ),
        path,
        generation: 1
      )
    end

    action = accepted_job.fetch("actions").first
    action["claims"] = [
      action_claim(1, "released").merge(
        "occurrence_id" => "occ-#{'f' * 64}"
      )
    ]
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(
        :validate_action_claims!,
        action,
        path,
        occurrence_id: occurrence_id
      )
    end

    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(
        :validate_discovery_attempt_transition!, [ discovery ], [], path
      )
    end
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(
        :validate_discovery_attempt_transition!,
        [ discovery ],
        [ diagnostic ],
        path
      )
    end
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(
        :validate_transition_history!, [ transition ], [], path
      )
    end
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(:occurrence_id!, "bad", "occurrence", path)
    end
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(:intent_id!, "bad", "intent", path)
    end
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.validate_transition_semantic!(
        transition, semantic: {}, path: path
      )
    end
  end

  def test_record_validator_rejects_a_well_formed_but_mismatched_semantic_digest
    semantic = {
      "intent_id" => "intent-#{"1" * 64}",
      "module" => "architecture-patrol",
      "occurrence_id" => "occ-#{"2" * 64}",
      "owner_epoch" => 1,
      "sink" => "branch",
      "target" => "main",
      "idempotency_key" => "effect-#{"3" * 64}",
      "scope" => { "repository" => "acme/demo" }
    }
    transition = {
      "semantic_digest" =>
        Hive::RefactorPatrol::TransitionEvidence.semantic_digest(semantic)
        .sub(/\A./, "f")
    }

    error = assert_raises(
      Hive::RefactorPatrol::JobStore::InconsistentRecord
    ) do
      validator.validate_transition_semantic!(
        transition,
        semantic: semantic,
        path: "/tmp/job.json"
      )
    end

    assert_match(/semantic digest does not match/, error.message)
  end

  def test_claim_transitions_build_and_advance_claims_without_io
    transitions = Hive::RefactorPatrol::ClaimTransitions.new(
      inconsistent_record: Hive::RefactorPatrol::JobStore::InconsistentRecord
    )
    prior = { "generation" => 2 }
    claim = transitions.build_action(
      claims: [ prior ],
      owner: "worker",
      owner_pid: 101,
      owner_process_start_time: "start",
      occurrence_id: "occ-#{'1' * 64}",
      authority: "full",
      now: T0,
      lease_sec: 60
    )

    assert_equal 3, claim.fetch("generation")
    assert_equal "claimed", claim.fetch("state")
    assert_equal (T0 + 60).iso8601, claim.fetch("expires_at")

    transitions.attach_process!(
      claim,
      pid: 202,
      process_start_time: "child-start",
      pgid: 203,
      now: T0 + 5,
      invalid_message: "invalid child"
    )
    assert_equal "running", claim.fetch("state")
    assert_equal 202, claim.fetch("pid")

    transitions.renew!(claim, now: T0 + 10, lease_sec: 90)
    assert_equal (T0 + 100).iso8601, claim.fetch("expires_at")

    transitions.finish!(
      claim,
      state: "released",
      outcome: "retry",
      now: T0 + 20,
      next_eligible_at: (T0 + 80).iso8601
    )
    assert_equal "released", claim.fetch("state")
    assert_equal "retry", claim.fetch("outcome")
    assert_equal (T0 + 80).iso8601, claim.fetch("next_eligible_at")

    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      transitions.attach_process!(
        claim,
        pid: 1,
        process_start_time: "",
        pgid: 1,
        now: T0,
        invalid_message: "invalid child"
      )
    end
  end

  def test_job_indexes_project_terminal_aggregates_deterministically
    projector = Hive::RefactorPatrol::JobIndexes.new(
      schema_version: Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
      dispositions: Hive::RefactorPatrol::JobStore::DISPOSITIONS,
      inconsistent_record: Hive::RefactorPatrol::JobStore::InconsistentRecord
    )
    records = [
      terminal_job("job-b", owner_job_id: "job-a", disposition: "flagged"),
      terminal_job("job-a", owner_job_id: "job-a", disposition: "accepted"),
      valid_job("job_id" => "queued-job")
    ]

    indexes = projector.project(records)
    fingerprint = indexes.fetch("fingerprints").fetch("fingerprints").fetch("fp-1")
    assert_equal %w[job-a job-b], fingerprint.fetch("occurrences").map { |item| item.fetch("job_id") }
    assert_equal [ "action-1" ], fingerprint.fetch("canonical_action_ids")
    assert_equal "job-a", indexes.dig("actions", "actions", "action-1", "owner_job_id")
    assert_equal Hive::RefactorPatrol::JobIndexes::FINGERPRINT_SCHEMA,
                 indexes.dig("fingerprints", "schema")
  end

  def test_job_indexes_reject_links_without_a_terminal_owner
    projector = Hive::RefactorPatrol::JobIndexes.new(
      schema_version: Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
      dispositions: Hive::RefactorPatrol::JobStore::DISPOSITIONS,
      inconsistent_record: Hive::RefactorPatrol::JobStore::InconsistentRecord
    )

    error = assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      projector.project([ terminal_job("job-b", owner_job_id: "missing", disposition: "flagged") ])
    end
    assert_match "links to missing owner job", error.message
  end

  private

  def validator
    @validator ||= Hive::RefactorPatrol::JobRecordValidator.new(
      contract: Hive::RefactorPatrol::JobStore
    )
  end

  def mutate_job(job)
    copy = deep_copy(job)
    yield copy
    copy
  end

  def accepted_job
    aggregate = valid_job("state" => "acting")
    aggregate.dig("dispositions", "accepted") << {
      "id" => "thesis-1", "feature_id" => "feature-1", "fingerprint" => "fp-1",
      "score" => 0.9, "admissible" => true, "reasons" => []
    }
    aggregate["actions"] << {
      "canonical_action_id" => "action-1", "thesis_id" => "thesis-1",
      "thesis_fingerprint" => "fp-1", "kind" => "fix", "owner_job_id" => "job-1",
      "outcome" => "queued", "terminal" => false, "receipts" => {},
      "claims" => [], "transitions" => []
    }
    aggregate
  end

  def action_policy
    valid_job.fetch("policy").merge(
      "action" => {
        "default_branch" => "main", "auto_fix_agent" => "codex", "min_confidence" => "medium",
        "commands" => {
          "docs" => nil, "format" => nil, "lint" => nil, "typecheck" => nil, "test" => nil
        },
        "caps" => {
          "single_feature_only" => true, "allow_dependency_bumps" => false,
          "allow_public_api_changes" => false, "allow_cross_feature" => false
        },
        "issue_min_leverage_score" => 0.5
      }
    )
  end

  def action_claim(generation, state)
    {
      "owner" => "worker", "owner_pid" => nil, "owner_process_start_time" => nil,
      "occurrence_id" => "occ-#{Digest::SHA256.hexdigest('job-1')}",
      "generation" => generation, "state" => state, "authority" => "full",
      "claimed_at" => T0.iso8601, "heartbeat_at" => T0.iso8601,
      "expires_at" => (T0 + 60).iso8601, "pid" => nil,
      "process_start_time" => nil, "pgid" => nil,
      "finished_at" => nil, "outcome" => nil, "next_eligible_at" => nil
    }
  end

  def effect_transition
    {
      "intent_id" => "intent-#{'1' * 64}",
      "operation" => "test",
      "generation" => 1,
      "semantic_digest" => "a" * 64,
      "outcome" => "applied",
      "error_code" => nil,
      "recorded_at" => T0.iso8601
    }
  end

  def diagnostic_attempt(occurrence_id, transition)
    {
      "kind" => "action_block",
      "occurrence_id" => occurrence_id,
      "generation" => 1,
      "state" => "blocked",
      "reason" => "retry",
      "evidence" => {},
      "transitions" => [ transition ],
      "finished_at" => T0.iso8601,
      "next_eligible_at" => (T0 + 60).iso8601,
      "action_claim_generations" => { "action-1" => 0 }
    }
  end

  def job_transition_attempt(occurrence_id, transition)
    {
      "kind" =>
        Hive::RefactorPatrol::JobStore::JOB_TRANSITION_ATTEMPT_KIND,
      "operation" => "test",
      "occurrence_id" => occurrence_id,
      "generation" => 1,
      "transitions" => [ transition ],
      "recorded_at" => T0.iso8601
    }
  end

  def discovery_attempt(occurrence_id, transition)
    {
      "kind" => Hive::RefactorPatrol::JobStore::DISCOVERY_ATTEMPT_KIND,
      "owner" => "worker",
      "owner_pid" => nil,
      "owner_process_start_time" => nil,
      "occurrence_id" => occurrence_id,
      "generation" => 1,
      "state" => "released",
      "transitions" => [ transition ],
      "claimed_at" => T0.iso8601,
      "heartbeat_at" => T0.iso8601,
      "expires_at" => (T0 + 60).iso8601,
      "pid" => nil,
      "process_start_time" => nil,
      "pgid" => nil,
      "finished_at" => T0.iso8601,
      "outcome" => "retry",
      "next_eligible_at" => (T0 + 60).iso8601
    }
  end

  def assert_invalid_attempt(attempt, occurrence_id, path)
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.send(
        :validate_discovery_attempts!,
        [ attempt ],
        path,
        occurrence_id: occurrence_id
      )
    end
  end

  def publication_job
    aggregate = accepted_job
    patch = {
      "branch" => "hive-refactor/action-1", "publication_base_sha" => "a" * 40,
      "commit_sha" => "b" * 40
    }
    aggregate.dig("actions", 0)["receipts"] = Hive::RefactorPatrol::PublicationAttempt.ensure_for_patch(
      receipts: {}, patch_receipt: patch, recorded_at: T0.iso8601
    )
    aggregate
  end

  def publication_payload(phase)
    common = {
      "canonical_action_id" => "action-1", "repository" => "acme/demo",
      "branch" => "hive-refactor/action-1", "commit_sha" => "b" * 40
    }
    case phase
    when "push_intent"
      common.merge("operation" => "push_branch", "expected_remote_oid" => nil)
    when "push_complete"
      common.merge("operation" => "push_branch_complete", "remote_oid" => "b" * 40)
    end
  end

  def append_publication_phase!(aggregate, phase, payload)
    attempts = aggregate.dig("actions", 0, "receipts", "publication_attempts")
    attempts.values.first[phase] = payload
  end

  def assert_invalid_job(job, message)
    error = assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      validator.validate_job!(job, path: "/tmp/job.json")
    end
    assert_match message, error.message
  end

  def valid_job(overrides = {})
    job_id = overrides.fetch("job_id", "job-1")
    {
      "schema" => Hive::RefactorPatrol::JobStore::SCHEMA,
      "schema_version" => Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
      "job_id" => job_id,
      "occurrence_id" => "occ-#{Digest::SHA256.hexdigest(job_id)}",
      "intake_transition_id" =>
        "intent-#{Digest::SHA256.hexdigest("intake:#{job_id}")}",
      "source" => {
        "url" => "https://github.com/acme/demo/pull/1",
        "number" => 1,
        "repository" => "acme/demo",
        "registration" => "demo",
        "base_branch" => "main",
        "base_sha" => "base",
        "merge_sha" => "merge"
      },
      "analysis_sha" => nil,
      "policy" => { "discovery" => true, "auto_fix" => false, "issue_filing" => false },
      "state" => "queued",
      "complete" => false,
      "dispositions" => { "accepted" => [], "flagged" => [], "suppressed" => [] },
      "feature_results" => [],
      "review_errors" => [],
      "zero_reason" => nil,
      "attempts" => [],
      "actions" => [],
      "created_at" => T0.iso8601,
      "updated_at" => T0.iso8601
    }.merge(overrides)
  end

  def terminal_job(job_id, owner_job_id:, disposition:)
    aggregate = valid_job(
      "job_id" => job_id,
      "state" => "complete",
      "complete" => true,
      "zero_reason" => nil
    )
    aggregate["dispositions"][disposition] << {
      "id" => "thesis-#{job_id}",
      "feature_id" => "feature-1",
      "fingerprint" => "fp-1",
      "score" => 0.9,
      "admissible" => true,
      "reasons" => disposition == "accepted" ? [] : [ "lower leverage" ]
    }
    aggregate["actions"] << {
      "canonical_action_id" => "action-1",
      "thesis_id" => "thesis-#{job_id}",
      "thesis_fingerprint" => "fp-1",
      "kind" => "fix",
      "owner_job_id" => owner_job_id,
      "outcome" => "complete",
      "terminal" => true,
      "receipts" => {},
      "claims" => [],
      "transitions" => []
    }
    aggregate
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end
end
