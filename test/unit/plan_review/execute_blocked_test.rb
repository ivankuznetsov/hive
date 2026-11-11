require "test_helper"
require "hive/plan_review"
require "hive/plan_review/execute_blocked"
require "hive/recovery"

class PlanReviewExecuteBlockedTest < Minitest::Test
  BLOCKED = Hive::PlanReview::ExecuteBlocked

  def test_marker_attrs_carry_the_guard_required_action_and_the_concrete_remedy
    error = Hive::PlanReview::TransitionBlocked.new(
      "canonical plan changed after plan review; required action: complete or resolve the plan review",
      review_id: "pr-1", review_state: "cleared",
      required_action: "complete or resolve the plan review",
      blocked_reason: "canonical plan changed after plan review"
    )

    attrs = BLOCKED.marker_attrs(error, slug: "demo-260522-aaaa", from_stage: "4-execute")

    assert_equal "plan_review_blocked", attrs.fetch(:reason)
    assert_equal "canonical plan changed after plan review", attrs.fetch(:blocker)
    assert_equal "complete or resolve the plan review", attrs.fetch(:required_action)
    assert_equal [ "pr-1", "cleared" ], attrs.values_at(:review_id, :review_state)
    message = attrs.fetch(:message)
    assert_includes message, "plan review blocks execution (canonical plan changed after plan review)"
    assert_includes message, "Hive will not retry this automatically"
    assert_includes message, "`hive approve demo-260522-aaaa --to 3-plan --from 4-execute`"
    assert_includes message, "`hive plan-review demo-260522-aaaa restart`"
    assert_includes message, "`hive plan-review-run demo-260522-aaaa`"
    assert_includes message, "restore the reviewed plan.md and retry"
  end

  def test_restore_is_offered_only_when_the_plan_itself_changed
    remedy = BLOCKED.remedy(
      slug: "demo", from_stage: "6-review", blocked_reason: "plan review policy changed after resolution"
    )

    assert_includes remedy, "`hive approve demo --to 3-plan --from 6-review`"
    refute_includes remedy, "restore the reviewed plan.md"
    assert remedy.end_with?(".")
    refute_includes BLOCKED.message(slug: "demo", from_stage: "4-execute"), "()"
  end

  def test_blocked_reason_falls_back_to_the_guard_message_shape
    error = Hive::PlanReview::TransitionBlocked.new(
      "required plan review evidence is missing; required action: move the task back to plan"
    )

    assert_equal "required plan review evidence is missing", BLOCKED.blocked_reason(error)
    assert_equal "review blocked", BLOCKED.blocked_reason(Hive::PlanReview::TransitionBlocked.new("review blocked"))
  end

  def test_marker_predicate_and_remediation_fallback
    assert BLOCKED.marker?("reason" => "plan_review_blocked")
    assert BLOCKED.marker?(reason: "plan_review_blocked")
    refute BLOCKED.marker?("reason" => "implementer_failed")
    refute BLOCKED.marker?(nil)

    assert_equal "do this", BLOCKED.remediation("message" => "do this")
    assert_equal BLOCKED::FALLBACK_REMEDIATION, BLOCKED.remediation("message" => "  ")
    assert_equal BLOCKED::FALLBACK_REMEDIATION, BLOCKED.remediation(nil)
  end

  def test_recovery_names_both_operator_owned_error_reasons
    blocked = { "reason" => "plan_review_blocked", "message" => "move the task back to 3-plan" }
    refused = { "reason" => "model_unsupported", "message" => "set a supported model" }

    assert_equal "plan_review_blocked", Hive::Recovery.operator_owned_error_reason(blocked)
    assert_equal "model_unsupported", Hive::Recovery.operator_owned_error_reason(refused)
    assert_equal "move the task back to 3-plan", Hive::Recovery.operator_owned_error_remediation(blocked)
    assert_equal "set a supported model", Hive::Recovery.operator_owned_error_remediation(refused)

    refute Hive::Recovery.operator_owned_error?("reason" => "implementer_failed")
    refute Hive::Recovery.operator_owned_error?(nil)
    assert_nil Hive::Recovery.operator_owned_error_remediation("reason" => "implementer_failed")
  end
end
