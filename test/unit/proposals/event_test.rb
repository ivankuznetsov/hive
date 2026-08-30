require "test_helper"
require "hive/proposals/event"

class ProposalEventTest < Minitest::Test
  def test_builds_each_supported_event_variant
    evaluation = build_event(
      type: "evaluation",
      data: {
        "evaluator" => { "id" => "reviewer", "binding_fingerprint" => "b" * 64 },
        "method" => { "kind" => "benchmark", "label" => "held-out-recall" },
        "result" => { "outcome" => "pass", "metrics" => { "recall" => 0.91 } },
        "rationale" => "Improved recall", "evidence" => [], "links" => []
      }
    )
    decision = build_event(
      version: 2,
      type: "decision",
      data: {
        "outcome" => "accepted", "considered_evaluation_ids" => [ evaluation.event_id ],
        "considered_evaluations" => [
          {
            "evaluation_id" => evaluation.event_id, "evaluator_id" => "reviewer",
            "method" => "held-out-recall", "outcome" => "pass",
            "result_digest" => "c" * 64
          }
        ],
        "rationale_category" => "evaluated", "rationale" => "Thresholds passed",
        "authority" => authority, "links" => [],
        "observed_head" => { "version" => 0, "digest" => "d" * 64 }
      }
    )
    supersession = build_event(
      version: 3, type: "supersession",
      data: {
        "successor_id" => "prp-00000000-0000-4000-8000-000000000002",
        "authority" => authority, "observed_head" => { "version" => 2, "digest" => "e" * 64 }
      }
    )
    rollback = build_event(
      version: 4, type: "rollback",
      data: {
        "reverted_revision" => "v2", "reason" => "Production regression",
        "external_revert" => { "kind" => "commit", "reference" => "f" * 40 },
        "authority" => authority, "observed_head" => { "version" => 3, "digest" => "a" * 64 }
      }
    )

    assert_equal %w[evaluation decision supersession rollback],
                 [ evaluation, decision, supersession, rollback ].map(&:type)
    assert_equal decision.to_h, Hive::Proposals::Event.new(decision.to_h).to_h
  end

  def test_rejects_unevaluated_acceptance_and_malformed_results
    error = assert_raises(Hive::Proposals::InvalidEvent) do
      build_event(
        type: "decision",
        data: {
          "outcome" => "accepted", "considered_evaluation_ids" => [],
          "considered_evaluations" => [], "rationale_category" => "no_evaluation",
          "rationale" => "Trust me", "authority" => authority, "links" => [],
          "observed_head" => { "version" => 0, "digest" => "d" * 64 }
        }
      )
    end
    assert_match(/no_evaluation/, error.message)

    assert_raises(Hive::Proposals::InvalidEvent) do
      build_event(
        type: "evaluation",
        data: {
          "evaluator" => { "id" => "reviewer", "binding_fingerprint" => "b" * 64 },
          "method" => { "kind" => "benchmark", "label" => "held-out-recall" },
          "result" => { "outcome" => "maybe", "metrics" => {} },
          "rationale" => "unknown", "evidence" => [], "links" => []
        }
      )
    end
  end

  private

  def build_event(version: 1, type:, data:)
    Hive::Proposals::Event.build(
      event_id: "pev-00000000-0000-4000-8000-%012d" % version,
      proposal_id: "prp-00000000-0000-4000-8000-000000000001",
      version:, type:, data:, source_event_id: "pse-#{'a' * 64}",
      provenance: {
        "task_id" => "43059", "task_generation" => 1,
        "ownership_generation" => "owner-1", "attempt_id" => "attempt-1",
        "workflow_id" => "coding", "stage" => "4-execute",
        "actor" => { "id" => "alice", "kind" => "configured_identity" },
        "source_commit" => "a" * 40
      },
      occurred_at: "2026-08-30T12:00:00Z"
    )
  end

  def authority
    {
      "id" => "operator", "kind" => "operator",
      "policy_fingerprint" => "a" * 64
    }
  end
end
