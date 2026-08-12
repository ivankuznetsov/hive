require "test_helper"
require "hive/plan_review/coverage_evaluator"

class PlanReviewCoverageEvaluatorTest < Minitest::Test
  def test_standard_distinguishes_optional_partial_from_total_unavailability
    partial = Hive::PlanReview::CoverageEvaluator.evaluate(
      level: "standard",
      coverage: [
        row("whole_document", true, "completed"),
        row("adversarial", true, "completed"),
        row("security", false, "unsupported")
      ],
      adapter_outcomes: %w[partial_coverage success]
    )
    unavailable = Hive::PlanReview::CoverageEvaluator.evaluate(
      level: "standard",
      coverage: [
        row("whole_document", true, "unsupported"),
        row("adversarial", true, "unsupported")
      ],
      adapter_outcomes: %w[unsupported unsupported]
    )

    assert partial.degraded?
    assert_equal "partial_coverage", partial.degradation_reason
    assert unavailable.degraded?
    assert_equal "review_unavailable", unavailable.degradation_reason
  end

  def test_mandatory_requires_every_requested_item_or_named_waiver
    missing = Hive::PlanReview::CoverageEvaluator.evaluate(
      level: "mandatory",
      coverage: [
        row("whole_document", true, "completed"),
        row("adversarial", true, "completed"),
        row("security", false, "failed")
      ]
    )
    waived = Hive::PlanReview::CoverageEvaluator.evaluate(
      level: "mandatory",
      coverage: [
        row("whole_document", true, "completed"),
        row("adversarial", true, "completed"),
        row("security", false, "waived")
      ]
    )

    assert missing.blocked?
    assert_equal "security", missing.blockers.first.fetch("coverage")
    assert waived.complete?
  end

  private

  def row(name, required, status)
    { "name" => name, "required" => required, "status" => status }
  end
end
