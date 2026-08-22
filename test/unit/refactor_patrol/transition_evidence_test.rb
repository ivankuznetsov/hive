require "test_helper"
require "hive/refactor_patrol/transition_evidence"

class RefactorPatrolTransitionEvidenceTest < Minitest::Test
  Intent = Data.define(
    :intent_id, :module_name, :occurrence_id, :owner_epoch, :sink,
    :target, :idempotency_key, :scope
  )

  def test_projects_digests_and_records_the_exact_effect_semantic
    intent = Intent.new(
      intent_id: "intent-1", module_name: "architecture-patrol",
      occurrence_id: "occurrence-1", owner_epoch: 1, sink: "patrol-fix",
      target: "target-1", idempotency_key: "key-1", scope: "project"
    )

    semantic = Hive::RefactorPatrol::TransitionEvidence.semantic(intent)
    digest = Hive::RefactorPatrol::TransitionEvidence.semantic_digest(intent)
    record = Hive::RefactorPatrol::TransitionEvidence.record(
      intent, operation: "delivered", error_code: nil
    )

    assert_equal digest, Hive::RefactorPatrol::TransitionEvidence.semantic_digest(semantic)
    assert_equal digest, record.fetch("semantic_digest")
    assert_equal "delivered", record.fetch("operation")
  end

  def test_rejects_malformed_semantics_and_projects_matched_outcomes
    assert_raises(ArgumentError) do
      Hive::RefactorPatrol::TransitionEvidence.semantic_digest("bad")
    end

    accepted = Hive::RefactorPatrol::TransitionEvidence.matched_result(
      "outcome" => "delivered"
    )
    rejected = Hive::RefactorPatrol::TransitionEvidence.matched_result(
      "outcome" => "rejected", "error_code" => "policy"
    )

    assert_equal({ "transition_status" => "delivered" }, accepted.fetch("outcome"))
    assert_equal "policy", rejected.dig("outcome", "error_code")
  end
end
