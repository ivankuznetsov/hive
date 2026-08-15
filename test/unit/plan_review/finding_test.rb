require "test_helper"
require "hive/plan_review/finding"

class PlanReviewFindingTest < Minitest::Test
  def test_fingerprint_uses_semantic_and_anchored_evidence_not_display_order
    first = finding("display_order" => 1)
    retry_copy = finding("display_order" => 99)
    changed_scope = finding("evidence" => evidence.merge("anchor_digest" => "b" * 64))

    assert_equal first.fingerprint, retry_copy.fingerprint
    refute_equal first.fingerprint, changed_scope.fingerprint

    paraphrased = finding(
      "title" => "Rollback needs a guard",
      "description" => "Add an explicit reversible fallback."
    )
    assert_equal first.fingerprint, paraphrased.fingerprint
  end

  def test_lifecycle_is_closed_and_answer_is_not_resolution
    answered = finding("classification" => "manual", "lifecycle" => "answered")
    refute answered.resolved?
    refute answered.blocking?

    verified = finding("classification" => "manual", "lifecycle" => "verified")
    assert verified.resolved?
    refute verified.blocking?

    error = assert_raises(Hive::PlanReview::InvalidRecord) do
      finding("classification" => "vote")
    end
    assert_match(/classification/i, error.message)
  end

  def test_nested_evidence_cannot_mutate_a_finding
    value = finding

    assert_predicate value["evidence"], :frozen?
    assert_raises(FrozenError) { value["evidence"]["path"] = "other.md" }
    copy = value.to_h
    copy.fetch("evidence")["path"] = "other.md"
    assert_equal "plan.md", value["evidence"].fetch("path")
  end

  def test_symbol_and_array_attributes_are_stringified_not_rejected
    value = finding(answer: [ :approved, { note: :ok } ])

    assert_equal [ "approved", { "note" => "ok" } ], value["answer"]
  end

  def test_supplied_fingerprint_must_match_the_semantic_evidence
    error = assert_raises(Hive::PlanReview::InvalidRecord) do
      finding("fingerprint" => "prf-#{'0' * 64}")
    end

    assert_match(/fingerprint does not match/, error.message)
  end

  def test_rejects_blank_prose_unknown_grades_and_unordered_evidence
    {
      /source must be a non-empty string/ => { "source" => "  " },
      /risk must be one of/ => { "risk" => "extreme" },
      /lifecycle must be one of/ => { "lifecycle" => "invented" },
      /display_order must be a positive integer/ => { "display_order" => 0 },
      /valid line range/ => { "evidence" => evidence.merge("end_line" => 9) }
    }.each do |message, overrides|
      error = assert_raises(Hive::PlanReview::InvalidRecord) { finding(overrides) }
      assert_match message, error.message
    end
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
