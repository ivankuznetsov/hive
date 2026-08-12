require "test_helper"
require "hive/plan_review/decision"

class PlanReviewDecisionTest < Minitest::Test
  def test_decision_id_is_stable_for_the_same_semantic_action
    first = decision("decided_at" => "2026-08-12T12:00:00Z")
    replay = decision("decided_at" => "2026-08-12T12:05:00Z")

    assert_equal first.decision_id, replay.decision_id
    assert first.authority_action?
  end

  def test_rejects_unknown_actions_and_malformed_observation_identity
    assert_raises(Hive::PlanReview::InvalidAction) do
      decision("action" => "invent_authority")
    end
    assert_raises(Hive::PlanReview::InvalidAction) do
      decision("expected_artifact_digest" => "stale")
    end
  end

  def test_rejects_non_iso_timestamp_without_leaking_a_type_error
    error = assert_raises(Hive::PlanReview::InvalidAction) do
      decision("decided_at" => nil)
    end

    assert_includes error.message, "decided_at"
  end

  private

  def decision(overrides = {})
    Hive::PlanReview::Decision.new(
      {
        "schema" => "hive-plan-review-decision", "schema_version" => 1,
        "review_id" => "pr-#{'a' * 64}", "task_generation" => "generation-1",
        "policy_fingerprint" => "b" * 64,
        "expected_artifact_digest" => "c" * 64,
        "target_fingerprint" => "prf-#{'d' * 64}",
        "action" => "approve_finding", "value" => {}, "reason" => nil,
        "origin" => "cli", "operator" => "operator", "policy_receipt" => nil,
        "decided_at" => "2026-08-12T12:00:00Z"
      }.merge(overrides)
    )
  end
end
