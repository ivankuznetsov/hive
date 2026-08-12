require "test_helper"
require "hive/plan_review/finding"

class PlanReviewFindingTest < Minitest::Test
  def test_fingerprint_uses_semantic_and_anchored_evidence_not_display_order
    first = finding("display_order" => 1)
    retry_copy = finding("display_order" => 99)
    changed_scope = finding("evidence" => evidence.merge("anchor_digest" => "b" * 64))

    assert_equal first.fingerprint, retry_copy.fingerprint
    refute_equal first.fingerprint, changed_scope.fingerprint
  end

  def test_lifecycle_is_closed_and_answer_is_not_resolution
    answered = finding("classification" => "manual", "lifecycle" => "answered")
    refute answered.resolved?
    assert answered.blocking?

    verified = finding("classification" => "manual", "lifecycle" => "verified")
    assert verified.resolved?
    refute verified.blocking?

    error = assert_raises(Hive::PlanReview::InvalidRecord) do
      finding("classification" => "vote")
    end
    assert_match(/classification/i, error.message)
  end

  private

  def finding(overrides = {})
    Hive::PlanReview::Finding.build(
      {
        "source" => "whole_document",
        "classification" => "gated_auto",
        "risk" => "high",
        "title" => "Missing rollback guard",
        "description" => "The plan needs an explicit rollback guard.",
        "evidence" => evidence,
        "lifecycle" => "open",
        "display_order" => 1
      }.merge(overrides)
    )
  end

  def evidence
    {
      "path" => "plan.md",
      "start_line" => 10,
      "end_line" => 12,
      "anchor_digest" => "a" * 64
    }
  end
end
