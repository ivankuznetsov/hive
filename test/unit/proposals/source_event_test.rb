require "test_helper"
require "json_schemer"
require "hive/proposals/source_event"
require "hive/schemas"

class ProposalSourceEventTest < Minitest::Test
  def test_submission_is_closed_private_and_bound_to_the_durable_attempt
    event = Hive::Proposals::SourceEvent.submission(
      source_event_id: source_id("a"), proposal_id: proposal_id,
      proposal_binding: proposal_binding, task_binding: task_binding,
      proposed_change: "Use api_key=abcdefghijklmnopqrstuv in the candidate",
      motivation: "Improve review recall", evidence: [ evidence ],
      artifact: {
        "reference" => "artifacts/candidate.json", "digest" => "d" * 64,
        "bytes" => 128, "media_type" => "application/json"
      },
      created_at: "2026-08-30T12:00:00Z"
    )

    assert_equal "candidate_submitted", event.kind
    assert_equal proposal_id, event.proposal_id
    assert_equal "restricted", event.to_h.dig("payload", "evidence", 0, "visibility")
    refute event.to_h.dig("payload", "evidence", 0).key?("summary")
    assert_includes event.to_h.dig("payload", "proposed_change"), "[REDACTED:generic_api_key]"
    assert_equal "attempt-1", event.to_h.dig("binding", "attempt_id")
    assert_equal "d" * 64, event.provenance(source_commit: "a" * 40).fetch("artifact_digest")
    assert_equal event.to_h, Hive::Proposals::SourceEvent.new(event.to_h).to_h
    assert_match(/\A[0-9a-f]{64}\z/, event.digest)
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-proposal-source-event")))
    )
    assert schemer.valid?(event.to_h)
  end

  def test_evaluation_requires_the_admitted_evaluator_and_matching_proposal_subject
    unbound = Marshal.load(Marshal.dump(proposal_binding))
    unbound["evaluator"] = nil

    assert_raises(Hive::Proposals::Unauthorized) do
      Hive::Proposals::SourceEvent.evaluation(
        source_event_id: source_id("b"), proposal_id: proposal_id,
        proposal_binding: unbound, task_binding: task_binding,
        method: method_fact, result: result_fact, rationale: "pass",
        evidence: [ evidence ], links: [], created_at: "2026-08-30T12:00:00Z"
      )
    end

    mismatch = Marshal.load(Marshal.dump(proposal_binding))
    mismatch.dig("subject")["proposal_id"] = "prp-00000000-0000-4000-8000-000000000009"
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::SourceEvent.evaluation(
        source_event_id: source_id("b"), proposal_id: proposal_id,
        proposal_binding: mismatch, task_binding: task_binding,
        method: method_fact, result: result_fact, rationale: "pass",
        evidence: [ evidence ], links: [], created_at: "2026-08-30T12:00:00Z"
      )
    end
  end

  def test_binding_artifact_and_payload_validation_is_closed
    binding = Marshal.load(Marshal.dump(proposal_binding))
    binding["schema_version"] = 2
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::SourceEvent.normalize_proposal_binding(binding)
    end

    subject = proposal_binding.fetch("subject").merge("kind" => "prompt")
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::SourceEvent.normalize_subject(subject)
    end

    invalid_task = task_binding.merge("task_generation" => [])
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::SourceEvent.normalize_task_binding(invalid_task)
    end

    evaluator = Marshal.load(Marshal.dump(proposal_binding.fetch("evaluator")))
    evaluator.dig("admission")["workflows"] = %w[coding coding]
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::SourceEvent.normalize_evaluator(evaluator)
    end

    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::SourceEvent.normalize_payload(
        "future_event", {}, policy: proposal_binding.fetch("policy")
      )
    end
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::SourceEvent.normalize_artifact(
        { "reference" => "artifact.json", "digest" => "d" * 64,
          "bytes" => -1, "media_type" => "application/json" },
        policy: proposal_binding.fetch("policy")
      )
    end
  end

  def test_replay_rejects_open_envelopes_subject_mismatch_and_lost_evaluator_binding
    submission = submission_event.to_h
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::SourceEvent.new(submission.merge("extra" => true))
    end

    mismatch = Marshal.load(Marshal.dump(submission))
    mismatch.dig("subject")["proposal_id"] = "prp-00000000-0000-4000-8000-000000000009"
    assert_raises(Hive::Proposals::InvalidRecord) { Hive::Proposals::SourceEvent.new(mismatch) }

    evaluation = Hive::Proposals::SourceEvent.evaluation(
      source_event_id: source_id("e"), proposal_id: proposal_id,
      proposal_binding: proposal_binding, task_binding: task_binding,
      method: method_fact, result: result_fact, rationale: "pass",
      evidence: [ evidence ], links: [], created_at: "2026-08-30T12:00:00Z"
    ).to_h
    evaluation["evaluator"] = nil
    assert_raises(Hive::Proposals::Unauthorized) do
      Hive::Proposals::SourceEvent.new(evaluation)
    end
  end

  def test_canonical_shaped_evidence_is_intersected_at_admission_but_preserved_on_replay
    canonical = {
      "label" => "benchmark", "digest" => "a" * 64, "bytes" => 12,
      "media_type" => "text/plain", "visibility" => "project",
      "retention" => { "policy" => "project", "enforcement" => "none" },
      "summary" => "instruction-bearing summary"
    }
    event = Hive::Proposals::SourceEvent.submission(
      source_event_id: source_id("f"), proposal_id: proposal_id,
      proposal_binding: proposal_binding, task_binding: task_binding,
      proposed_change: "Change review", motivation: "Improve recall",
      evidence: [ canonical ], created_at: "2026-08-30T12:00:00Z"
    )

    stored = event.to_h.dig("payload", "evidence", 0)
    assert_equal "restricted", stored.fetch("visibility")
    assert_equal "task", stored.dig("retention", "policy")
    refute stored.key?("summary")

    historical = event.to_h
    historical.dig("payload", "evidence", 0).merge!(
      "visibility" => "project",
      "retention" => { "policy" => "project", "enforcement" => "none" },
      "summary" => "historical summary"
    )
    replay = Hive::Proposals::SourceEvent.new(historical)
    assert_equal "historical summary", replay.to_h.dig("payload", "evidence", 0, "summary")
  end

  private

  def source_id(character) = "pse-#{character * 64}"
  def proposal_id = "prp-00000000-0000-4000-8000-000000000001"

  def task_binding
    {
      "project" => "hive", "task_id" => "43059", "task_slug" => "proposal-task",
      "workflow_id" => "coding", "stage" => "4-execute", "task_generation" => 1,
      "ownership_generation" => "owner-1", "attempt_id" => "attempt-1"
    }
  end

  def proposal_binding
    {
      "schema_version" => 1,
      "subject" => {
        "kind" => "skill", "reference" => "agent-skills/reviewer",
        "revision" => "v2", "proposal_id" => proposal_id
      },
      "actor" => { "id" => "alice", "kind" => "proposer", "binding" => "team:skills" },
      "evaluator" => {
        "id" => "benchmark-reviewer", "fingerprint" => "b" * 64,
        "configuration_fingerprint" => "c" * 64,
        "admission" => {
          "workflows" => [ "coding" ], "stages" => [ "4-execute" ],
          "agent_profiles" => [ "codex" ]
        }
      },
      "configuration_fingerprint" => "c" * 64,
      "policy" => {
        "visibility" => "restricted", "retention" => "task",
        "allowed_link_schemes" => [ "https" ]
      }
    }
  end

  def evidence
    {
      "label" => "benchmark", "content" => "score=0.91", "media_type" => "text/plain"
    }
  end

  def method_fact
    { "kind" => "benchmark", "label" => "held-out recall", "reference" => "https://example.test/run" }
  end

  def result_fact
    { "outcome" => "pass", "metrics" => { "recall" => 0.91 } }
  end

  def submission_event
    Hive::Proposals::SourceEvent.submission(
      source_event_id: source_id("d"), proposal_id: proposal_id,
      proposal_binding: proposal_binding, task_binding: task_binding,
      proposed_change: "Change review", motivation: "Improve recall",
      evidence: [ evidence ], created_at: "2026-08-30T12:00:00Z"
    )
  end
end
