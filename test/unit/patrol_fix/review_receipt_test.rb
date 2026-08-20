require "test_helper"
require "tmpdir"
require "hive/patrol_fix/review_receipt"

class PatrolFixReviewReceiptTest < Minitest::Test
  def test_reads_only_the_closed_allowed_route_contract
    report = Hive::PatrolFix::ReviewReceipt.parse(
      JSON.generate(
        "schema" => "hive-patrol-fix-review-report", "schema_version" => 1,
        "route" => "rework", "rationale" => "The failed regression remains relevant.",
        "evidence" => [ "The focused validation exited 1." ],
        "blocker_owner" => "review_gate"
      ),
      allowed_routes: %w[publish rework escalate reject blocked]
    )

    assert_equal "rework", report.route
    assert_equal [ "The focused validation exited 1." ], report.evidence
  end

  def test_rework_is_rejected_when_the_controller_omits_it_at_the_cap
    error = assert_raises(Hive::PatrolFix::ReviewReceipt::InvalidReport) do
      Hive::PatrolFix::ReviewReceipt.parse(
        JSON.generate(
          "schema" => "hive-patrol-fix-review-report", "schema_version" => 1,
          "route" => "rework", "rationale" => "Try again.",
          "evidence" => [ "Still failing." ], "blocker_owner" => "review_gate"
        ),
        allowed_routes: %w[publish escalate reject blocked]
      )
    end

    assert_includes error.message, "not controller-allowed"
  end

  def test_rejects_extra_identity_fields_from_the_model
    document = {
      "schema" => "hive-patrol-fix-review-report", "schema_version" => 1,
      "route" => "publish", "rationale" => "Current patch is adequate.",
      "evidence" => [ "Validation passed." ], "blocker_owner" => "review_gate",
      "task" => "attacker-selected-task"
    }

    assert_raises(Hive::PatrolFix::ReviewReceipt::InvalidReport) do
      Hive::PatrolFix::ReviewReceipt.parse(JSON.generate(document), allowed_routes: %w[publish])
    end
  end
end
