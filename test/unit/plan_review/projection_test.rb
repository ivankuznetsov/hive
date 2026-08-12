require "test_helper"
require "hive/plan_review/projection"

class PlanReviewProjectionTest < Minitest::Test
  def test_freshness_binds_generation_plan_and_policy
    projection = Hive::PlanReview::Projection.new(record)

    assert projection.fresh?(
      task_generation: "generation-1", plan_digest: "b" * 64,
      policy_fingerprint: "c" * 64
    )
    refute projection.fresh?(
      task_generation: "generation-2", plan_digest: "b" * 64,
      policy_fingerprint: "c" * 64
    )
    assert projection.execution_allowed?(
      task_generation: "generation-1", plan_digest: "b" * 64,
      policy_fingerprint: "c" * 64
    )
  end

  def test_summary_counts_findings_and_coverage_without_rederiving_state
    data = record.to_h.merge(
      "findings" => [
        finding("gated_auto", "open"), finding("manual", "answered"),
        finding("fyi", "open"), finding("safe_auto", "verified")
      ],
      "coverage" => [
        coverage("whole_document", "completed"), coverage("adversarial", "failed")
      ]
    )
    summary = Hive::PlanReview::Projection.new(Hive::PlanReview::Record.new(data)).summary

    assert_equal 1, summary.dig("finding_counts", "open_gated")
    assert_equal 1, summary.dig("finding_counts", "open_manual")
    assert_equal 1, summary.dig("coverage_counts", "completed")
    assert_equal 1, summary.dig("coverage_counts", "failed")
    assert_equal "none", summary.fetch("blocker_owner")
    assert_nil summary.fetch("blocker_reason")
    assert_nil summary.fetch("retry_at")
    assert_equal "unknown", summary.dig("freshness", "status")
  end

  def test_empty_summary_has_the_complete_status_shape
    summary = Hive::PlanReview::Projection.empty_summary(
      state: "uninitialized", freshness_status: "not_initialized",
      required_action: "run the plan review", blocker_owner: "agent"
    )

    assert_nil summary.fetch("review_id")
    assert_equal 0, summary.dig("coverage_counts", "completed")
    assert_equal 0, summary.dig("finding_counts", "open_manual")
    assert_equal "not_initialized", summary.dig("freshness", "status")
    refute summary.fetch("execution_allowed")
  end

  private

  def record
    Hive::PlanReview::Record.new(
      "schema" => "hive-plan-review", "schema_version" => 1, "kind" => "projection",
      "review_id" => "pr-#{'a' * 64}", "prior_review_id" => nil, "version" => 1,
      "task_id" => "task-1", "task_generation" => "generation-1",
      "plan_digest" => "b" * 64, "candidate_plan_digest" => nil,
      "policy_fingerprint" => "c" * 64, "computed_level" => "standard",
      "effective_level" => "standard", "state" => "cleared", "outcome" => "cleared",
      "attempt_ids" => [], "current_attempt_id" => nil, "coverage" => [],
      "findings" => [], "decisions" => [], "routes" => [], "artifacts" => {},
      "blockers" => [], "required_action" => nil, "degradation_reason" => nil,
      "execution_allowed" => true, "created_at" => "2026-08-12T12:00:00.000000Z",
      "updated_at" => "2026-08-12T12:01:00.000000Z"
    )
  end

  def finding(classification, lifecycle)
    Hive::PlanReview::Finding.build(
      "source" => "whole_document", "classification" => classification, "risk" => "low",
      "title" => "Finding #{classification}", "description" => "detail",
      "evidence" => {
        "path" => "plan.md", "start_line" => 1, "end_line" => 1,
        "anchor_digest" => Digest::SHA256.hexdigest(classification)
      },
      "lifecycle" => lifecycle, "display_order" => 1
    ).to_h
  end

  def coverage(name, status)
    {
      "name" => name, "required" => true, "status" => status,
      "fingerprint" => Hive::PlanReview::Identity.coverage(
        review_id: record.review_id, name:, policy_fingerprint: record.policy_fingerprint
      )
    }
  end
end
