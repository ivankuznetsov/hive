require "test_helper"
require "hive/plan_review/approval_policy"

class PlanReviewApprovalPolicyTest < Minitest::Test
  NOW = Time.utc(2026, 8, 12, 12)

  def test_exact_current_policy_matches_and_emits_a_bound_receipt
    match = Hive::PlanReview::ApprovalPolicy.match(
      finding:, policies: [ policy ], review_id: review_id,
      policy_fingerprint: "c" * 64, now: NOW,
      policy_id: "safe_api_change", policy_version: 3
    )

    refute_nil match
    assert_equal "safe_api_change", match.receipt.fetch("policy_id")
    assert_equal 3, match.receipt.fetch("policy_version")
    assert_equal "lib/api.rb", match.receipt.fetch("path")
    assert_equal review_id, match.receipt.fetch("review_id")
  end

  def test_expired_revoked_broad_or_wrong_scope_policy_does_not_authorize
    variants = [
      policy.merge("valid_until" => "2026-08-12T11:59:59Z"),
      policy.merge("revoked" => true),
      policy.merge("paths" => [ "lib/**" ]),
      policy.merge("paths" => [ "lib/other.rb" ]),
      policy.merge("risk" => "high"),
      policy.merge("action" => "waive_coverage")
    ]

    variants.each do |candidate|
      assert_nil Hive::PlanReview::ApprovalPolicy.match(
        finding:, policies: [ candidate ], review_id: review_id,
        policy_fingerprint: "c" * 64, now: NOW
      )
    end
    assert_nil Hive::PlanReview::ApprovalPolicy.match(
      finding:, policies: [ policy ], review_id: review_id,
      policy_fingerprint: "c" * 64, now: NOW, policy_version: 4
    )
  end

  def test_unparsable_policy_version_filter_denies_instead_of_raising
    assert_nil Hive::PlanReview::ApprovalPolicy.match(
      finding:, policies: [ policy ], review_id: review_id,
      policy_fingerprint: "c" * 64, now: NOW,
      policy_id: "safe_api_change", policy_version: "not-an-integer"
    )
  end

  def test_policy_missing_its_validity_window_is_not_applicable
    assert_nil Hive::PlanReview::ApprovalPolicy.match(
      finding:, policies: [ policy.reject { |key, _| key == "valid_from" } ],
      review_id: review_id, policy_fingerprint: "c" * 64, now: NOW
    )
  end

  private

  def review_id = "pr-#{'a' * 64}"

  def finding
    Hive::PlanReview::Finding.new(
      "source" => "whole_document", "classification" => "gated_auto",
      "risk" => "medium", "title" => "Confirm compatibility",
      "description" => "The public response may change.",
      "evidence" => {
        "path" => "lib/api.rb", "start_line" => 4, "end_line" => 6,
        "anchor_digest" => "b" * 64
      },
      "lifecycle" => "open", "display_order" => 1
    )
  end

  def policy
    {
      "id" => "safe_api_change", "version" => 3,
      "action" => "approve_finding", "risk" => "medium",
      "paths" => [ "lib/api.rb" ],
      "valid_from" => "2026-08-12T00:00:00Z",
      "valid_until" => "2026-08-13T00:00:00Z", "revoked" => false
    }
  end
end
