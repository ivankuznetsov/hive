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

  def test_nested_action_value_is_immutable
    value = decision("value" => { "answer" => [ "approved" ] })

    assert_predicate value.value, :frozen?
    assert_predicate value.value.fetch("answer"), :frozen?
    assert_raises(FrozenError) { value.value.fetch("answer") << "changed" }
  end

  def test_supplied_decision_id_must_match_the_semantic_action
    error = assert_raises(Hive::PlanReview::InvalidAction) do
      decision("decision_id" => "prd-#{'0' * 64}")
    end

    assert_match(/does not match its semantic action/, error.message)
  end

  def test_rejects_values_that_cannot_round_trip_through_json
    error = assert_raises(Hive::PlanReview::InvalidAction) do
      decision("value" => { "score" => Float::NAN })
    end

    assert_match(/not JSON-safe/, error.message)
  end

  def test_rejects_malformed_envelope_target_and_attribution
    {
      /invalid plan review decision envelope/ => { "schema" => "hive-plan-review" },
      /decision target is malformed/ => { "task_generation" => "" },
      /decision reason must be text/ => { "reason" => 42 },
      /decision origin must be one of/ => { "origin" => "invented" },
      /decision operator must be non-empty/ => { "operator" => "   " }
    }.each do |message, overrides|
      error = assert_raises(Hive::PlanReview::InvalidAction) { decision(overrides) }
      assert_match message, error.message
    end
  end

  def test_policy_receipts_are_bound_to_policy_origin_and_this_review
    error = assert_raises(Hive::PlanReview::InvalidAction) do
      decision("origin" => "policy", "policy_receipt" => nil)
    end
    assert_match(/requires an approval policy receipt/, error.message)

    error = assert_raises(Hive::PlanReview::InvalidAction) do
      decision("origin" => "cli", "policy_receipt" => policy_receipt)
    end
    assert_match(/receipt is malformed/, error.message)

    error = assert_raises(Hive::PlanReview::InvalidAction) do
      decision(
        "origin" => "policy",
        "policy_receipt" => policy_receipt("review_id" => "pr-#{'f' * 64}")
      )
    end
    assert_match(/receipt identity is malformed/, error.message)

    error = assert_raises(Hive::PlanReview::InvalidAction) do
      decision(
        "origin" => "policy",
        "policy_receipt" => policy_receipt("matched_at" => "whenever")
      )
    end
    assert_match(/receipt is malformed/, error.message)
  end

  private

  def policy_receipt(overrides = {})
    {
      "policy_id" => "auto-approve-low", "policy_version" => 1,
      "policy_digest" => "e" * 64, "action" => "approve_finding",
      "risk" => "low", "path" => "plan.md",
      "review_id" => "pr-#{'a' * 64}", "policy_fingerprint" => "b" * 64,
      "matched_at" => "2026-08-12T12:00:00Z"
    }.merge(overrides)
  end

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
