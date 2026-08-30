require "test_helper"
require "hive/proposals/projection"

class ProposalProjectionTest < Minitest::Test
  def test_preserves_orthogonal_history_and_derives_effective_status
    record = build_record
    evaluation = build_event(1, "evaluation", evaluation_data("pass", 0.91))
    decision = build_event(
      2, "decision",
      {
        "outcome" => "accepted", "considered_evaluation_ids" => [ evaluation.event_id ],
        "considered_evaluations" => [
          {
            "evaluation_id" => evaluation.event_id, "evaluator_id" => "reviewer",
            "method" => "recall", "outcome" => "pass", "result_digest" => "c" * 64
          }
        ],
        "rationale_category" => "evaluated", "rationale" => "Passed",
        "authority" => authority, "links" => [],
        "observed_head" => { "version" => 0, "digest" => Hive::Proposals::Projection.empty_head_digest(record.proposal_id) }
      }
    )
    contradictory = build_event(3, "evaluation", evaluation_data("fail", 0.70))
    supersession = build_event(
      4, "supersession",
      {
        "successor_id" => "prp-00000000-0000-4000-8000-000000000002",
        "authority" => authority,
        "observed_head" => { "version" => 2, "digest" => "d" * 64 }
      }
    )
    rollback = build_event(
      5, "rollback",
      {
        "reverted_revision" => "v2", "reason" => "Regression",
        "external_revert" => { "kind" => "commit", "reference" => "f" * 40 },
        "authority" => authority,
        "observed_head" => { "version" => 4, "digest" => "e" * 64 }
      }
    )

    projection = Hive::Proposals::Projection.new(
      record:, events: [ rollback, contradictory, decision, evaluation, supersession ]
    )

    assert_equal "rolled_back", projection.status
    assert_equal "accepted", projection.decision.fetch("outcome")
    assert_equal 2, projection.evaluations.length
    assert_equal %w[pass fail], projection.evaluations.map { |item| item.dig("result", "outcome") }
    assert_equal supersession.data.fetch("successor_id"), projection.superseded_by
    assert_equal "v2", projection.rollback.fetch("reverted_revision")
    assert_equal 5, projection.lifecycle_head.fetch("version")
    assert_equal "none", projection.to_h.dig("retention", "enforcement")
  end

  def test_rejects_multiple_terminal_decisions_and_event_version_gaps
    decision_data = {
      "outcome" => "rejected", "considered_evaluation_ids" => [],
      "considered_evaluations" => [], "rationale_category" => "no_evaluation",
      "rationale" => "Not worth evaluating", "authority" => authority, "links" => [],
      "observed_head" => {
        "version" => 0,
        "digest" => Hive::Proposals::Projection.empty_head_digest(build_record.proposal_id)
      }
    }
    assert_raises(Hive::Proposals::InconsistentHistory) do
      Hive::Proposals::Projection.new(
        record: build_record,
        events: [ build_event(1, "decision", decision_data), build_event(2, "decision", decision_data) ]
      )
    end

    assert_raises(Hive::Proposals::InconsistentHistory) do
      Hive::Proposals::Projection.new(
        record: build_record,
        events: [ build_event(2, "evaluation", evaluation_data("pass", 0.9)) ]
      )
    end
  end

  private

  def build_record
    Hive::Proposals::Record.build(
      proposal_id: "prp-00000000-0000-4000-8000-000000000001",
      subject_kind: "workflow", subject_ref: "coding", revision: "v2",
      proposed_change: "Change review", motivation: "Improve recall",
      evidence: [
        {
          "label" => "score", "content" => "0.91", "visibility" => "project",
          "retention" => "task", "media_type" => "text/plain"
        }
      ],
      author: { "id" => "alice", "kind" => "proposer", "binding" => "team" },
      provenance:, source_event_id: "pse-#{'a' * 64}",
      created_at: "2026-08-30T12:00:00Z",
      policy: { "visibility" => "project", "retention" => "project" }
    )
  end

  def build_event(version, type, data)
    Hive::Proposals::Event.build(
      event_id: "pev-00000000-0000-4000-8000-%012d" % version,
      proposal_id: build_record.proposal_id, version:, type:, data:,
      source_event_id: "pse-#{version.to_s(16).rjust(64, '0')}",
      provenance:, occurred_at: "2026-08-30T12:%02d:00Z" % version
    )
  end

  def evaluation_data(outcome, score)
    {
      "evaluator" => { "id" => "reviewer", "binding_fingerprint" => "b" * 64 },
      "method" => { "kind" => "benchmark", "label" => "recall" },
      "result" => { "outcome" => outcome, "metrics" => { "recall" => score } },
      "rationale" => "Measured", "evidence" => [], "links" => []
    }
  end

  def provenance
    {
      "task_id" => "43059", "task_generation" => 1,
      "ownership_generation" => "owner-1", "attempt_id" => "attempt-1",
      "workflow_id" => "coding", "stage" => "4-execute",
      "actor" => { "id" => "alice", "kind" => "configured_identity" },
      "source_commit" => "a" * 40
    }
  end

  def authority
    { "id" => "operator", "kind" => "operator", "policy_fingerprint" => "a" * 64 }
  end
end
