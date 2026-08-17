require "test_helper"
require "hive/plan_review/clearance"

class PlanReviewClearanceTest < Minitest::Test
  def test_manual_finding_waits_for_answer_before_revision
    finding = build_finding("manual")
    result = Hive::PlanReview::Clearance.evaluate(
      level: "standard", coverage: complete_coverage, findings: [ finding ],
      adapter_outcomes: %w[success success], verification_outcome: nil,
      revision_required: false, revision_complete: false,
      verification_complete: false
    )

    assert_equal "awaiting_decision", result.state
    assert_match(/answer manual/, result.required_action)
    refute result.execution_allowed
  end

  def test_verification_blocker_stops_without_requesting_another_revision
    result = Hive::PlanReview::Clearance.evaluate(
      level: "standard", coverage: complete_coverage, findings: [],
      adapter_outcomes: %w[success success], verification_outcome: "success",
      revision_required: true, revision_complete: true,
      verification_complete: true,
      verification_blockers: [ { "reason" => "verification_finding" } ]
    )

    assert_equal "blocked", result.state
    assert_equal "blocked", result.outcome
    assert_match(/new linked plan/, result.required_action)
  end

  def test_gated_finding_asks_for_approval_rather_than_an_answer
    result = Hive::PlanReview::Clearance.evaluate(
      level: "standard", coverage: complete_coverage,
      findings: [ build_finding("gated_auto") ],
      adapter_outcomes: %w[success success], verification_outcome: nil,
      revision_required: false, revision_complete: false,
      verification_complete: false
    )

    assert_equal "awaiting_decision", result.state
    assert_match(/approve gated plan finding/, result.required_action)
  end

  def test_required_revision_precedes_verification
    result = Hive::PlanReview::Clearance.evaluate(
      level: "standard", coverage: complete_coverage, findings: [],
      adapter_outcomes: %w[success success], verification_outcome: nil,
      revision_required: true, revision_complete: false,
      verification_complete: false
    )

    assert_equal "revising", result.state
    assert_nil result.outcome
    assert_equal "revise plan with accepted findings", result.required_action
    refute result.execution_allowed
  end

  def test_completed_revision_waits_on_disposition_verification
    result = Hive::PlanReview::Clearance.evaluate(
      level: "standard", coverage: complete_coverage, findings: [],
      adapter_outcomes: %w[success success], verification_outcome: nil,
      revision_required: true, revision_complete: true,
      verification_complete: false
    )

    assert_equal "verifying", result.state
    assert_equal "run disposition verification", result.required_action
    refute result.execution_allowed
  end

  def test_optional_failed_coverage_degrades_without_blocking_clearance
    result = Hive::PlanReview::Clearance.evaluate(
      level: "mandatory",
      coverage: complete_coverage + [
        { "name" => "security", "required" => false, "status" => "failed" }
      ],
      findings: [], adapter_outcomes: %w[success success],
      verification_outcome: "success", revision_required: false,
      revision_complete: true, verification_complete: true
    )

    assert_equal "degraded_cleared", result.state
    assert_equal "degraded_cleared", result.outcome
    assert_empty result.blockers
    assert_equal "partial_coverage", result.degradation_reason
    assert result.execution_allowed
  end

  def test_required_failed_coverage_stops_clearance_with_a_waiver_action
    result = Hive::PlanReview::Clearance.evaluate(
      level: "mandatory",
      coverage: complete_coverage + [
        { "name" => "security", "required" => true, "status" => "failed" }
      ],
      findings: [], adapter_outcomes: %w[success success],
      verification_outcome: "success", revision_required: false,
      revision_complete: true, verification_complete: true
    )

    assert_equal "blocked", result.state
    assert_equal "blocked", result.outcome
    assert_equal "security", result.blockers.first.fetch("coverage")
    assert_match(/waive named coverage/, result.required_action)
    refute result.execution_allowed
  end

  private

  def build_finding(classification)
    Hive::PlanReview::Finding.new(
      "source" => "coherence", "classification" => classification, "risk" => "medium",
      "title" => "Question", "description" => "Clarify the plan.",
      "evidence" => {
        "path" => "plan.md", "start_line" => 1, "end_line" => 1,
        "anchor_digest" => "a" * 64
      },
      "lifecycle" => "open", "display_order" => 1
    )
  end

  def complete_coverage
    %w[whole_document adversarial].map do |name|
      { "name" => name, "required" => true, "status" => "completed" }
    end
  end
end
