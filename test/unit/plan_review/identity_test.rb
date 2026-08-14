require "test_helper"
require "hive/plan_review/identity"

class PlanReviewIdentityTest < Minitest::Test
  def test_logical_identity_is_stable_and_policy_or_plan_changes_roll_it
    first = Hive::PlanReview::Identity.logical(
      task_id: "task-1", plan_generation: "plan-a", policy_fingerprint: "b" * 64
    )
    same = Hive::PlanReview::Identity.logical(
      task_id: "task-1", plan_generation: "plan-a", policy_fingerprint: "b" * 64
    )
    changed = Hive::PlanReview::Identity.logical(
      task_id: "task-1", plan_generation: "plan-c", policy_fingerprint: "b" * 64
    )

    assert_equal first, same
    refute_equal first, changed
    assert_match(/\Apr-[0-9a-f]{64}\z/, first)
  end

  def test_attempts_are_distinct_and_decisions_are_idempotently_derived
    review_id = "pr-#{'a' * 64}"
    refute_equal Hive::PlanReview::Identity.attempt(review_id),
                 Hive::PlanReview::Identity.attempt(review_id)

    first = Hive::PlanReview::Identity.decision(
      review_id:, target_fingerprint: "finding-a", action: "approve", value: "yes"
    )
    same = Hive::PlanReview::Identity.decision(
      review_id:, target_fingerprint: "finding-a", action: :approve, value: "yes"
    )
    conflict = Hive::PlanReview::Identity.decision(
      review_id:, target_fingerprint: "finding-a", action: "approve", value: "no"
    )
    assert_equal first, same
    refute_equal first, conflict
  end

  def test_task_generation_falls_back_to_the_slug_on_a_bare_task
    bare = Data.define(:slug).new(slug: "slug-260812-abcd")
    other = Data.define(:slug).new(slug: "slug-260812-beef")

    assert_match(/\A[0-9a-f]{64}\z/, Hive::PlanReview::Identity.task_generation(bare))
    assert_equal Hive::PlanReview::Identity.task_generation(bare),
                 Hive::PlanReview::Identity.task_generation(bare)
    refute_equal Hive::PlanReview::Identity.task_generation(bare),
                 Hive::PlanReview::Identity.task_generation(other)
  end
end
