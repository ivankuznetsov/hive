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

  def test_mandatory_blocks_required_failures_but_degrades_for_optional_failures
    optional = Hive::PlanReview::CoverageEvaluator.evaluate(
      level: "mandatory",
      coverage: [
        row("whole_document", true, "completed"),
        row("adversarial", true, "completed"),
        row("security", false, "failed")
      ]
    )
    required = Hive::PlanReview::CoverageEvaluator.evaluate(
      level: "mandatory",
      coverage: [
        row("whole_document", true, "completed"),
        row("adversarial", true, "completed"),
        row("security", true, "failed")
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

    assert optional.degraded?
    assert_equal "partial_coverage", optional.degradation_reason
    assert required.blocked?
    assert_equal "security", required.blockers.first.fetch("coverage")
    assert waived.complete?
  end

  def test_failed_verification_blocks_mandatory_and_degrades_standard
    mandatory = Hive::PlanReview::CoverageEvaluator.evaluate(
      level: "mandatory",
      coverage: [ row("whole_document", true, "completed"), row("adversarial", true, "completed") ],
      adapter_outcomes: %w[success success], verification_outcome: "failed"
    )
    standard = Hive::PlanReview::CoverageEvaluator.evaluate(
      level: "standard",
      coverage: [ row("whole_document", true, "completed"), row("adversarial", true, "completed") ],
      adapter_outcomes: %w[success success], verification_outcome: "failed"
    )

    assert mandatory.blocked?
    assert_equal(
      { "owner" => "reviewer", "reason" => "verification_failed" },
      mandatory.blockers.fetch(0)
    )
    # Core coverage is intact, so a standard review degrades instead of blocking.
    assert standard.degraded?
    assert_equal "partial_coverage", standard.degradation_reason
  end

  def test_malformed_coverage_entries_are_rejected
    error = assert_raises(Hive::PlanReview::InvalidRecord) do
      Hive::PlanReview::CoverageEvaluator.evaluate(
        level: "standard", coverage: [ row("Whole Document", true, "completed") ]
      )
    end

    assert_match(/invalid plan review coverage entry/, error.message)
  end

  def test_merge_infers_a_failed_status_when_the_reviewer_reports_nothing
    merged = Hive::PlanReview::CoverageEvaluator.merge(
      requested: [ row("whole_document", true, "requested") ],
      observed: [], outcome: "success"
    )

    assert_equal "failed", merged.fetch(0).fetch("status")
  end

  private

  def row(name, required, status)
    { "name" => name, "required" => required, "status" => status }
  end
end
