require "test_helper"
require "hive/plan_review/checkpoint_custody"

class PlanReviewCheckpointCustodyTest < Minitest::Test
  def test_recovery_is_exact_versioned_and_covers_every_review_role
    diagnostic = Hive::PlanReview::CheckpointCustody::DIAGNOSTIC
    recoverable = %w[primary adversarial verification].map do |role|
      {
        "role" => role, "outcome" => "terminal_failure", "attempt_id" => "pra-#{role}",
        "diagnostic" => diagnostic, "diagnostic_source" => "runner"
      }
    end
    ignored = [
      recoverable.first.merge("diagnostic_source" => "reviewer"),
      recoverable.first.merge("diagnostic" => "reviewer modified protected artifacts: plan.md")
    ]

    routes = Hive::PlanReview::CheckpointCustody.recoverable_routes(recoverable)

    assert Hive::PlanReview::CheckpointCustody.recoverable?(recoverable)
    assert_equal %w[primary adversarial verification], routes.map { |route| route.fetch("role") }
    ignored.each do |route|
      refute Hive::PlanReview::CheckpointCustody.recoverable?([ route ])
    end

    recovered = recoverable + [
      Hive::PlanReview.recovery_reset_route(
        recoverable.first,
        "checkpoint_custody_recovery" => true,
        "checkpoint_custody_contract_version" => 1
      )
    ]
    recovered_roles = Hive::PlanReview::CheckpointCustody.recoverable_routes(recovered)
      .map { |route| route.fetch("role") }
    assert_equal %w[adversarial verification], recovered_roles

    malformed = recovered.last.merge("checkpoint_custody_contract_version" => "not-a-version")
    malformed_routes = recoverable + [ malformed ]
    malformed_roles = Hive::PlanReview::CheckpointCustody.recoverable_routes(malformed_routes)
      .map { |route| route.fetch("role") }
    assert_equal %w[adversarial verification], malformed_roles

    stale = recovered.last.merge("checkpoint_custody_contract_version" => 0)
    stale_roles = Hive::PlanReview::CheckpointCustody.recoverable_routes(recoverable + [ stale ])
      .map { |route| route.fetch("role") }
    assert_equal %w[primary adversarial verification], stale_roles

    superseded = [
      recoverable.first,
      recoverable.first.merge("outcome" => "success", "diagnostic" => nil)
    ]
    refute Hive::PlanReview::CheckpointCustody.recoverable?(superseded)

    unrelated_failure = recoverable.first.merge("diagnostic" => "reviewer modified plan.md")
    refute Hive::PlanReview::CheckpointCustody.recoverable?(
      [ recoverable.first, unrelated_failure ]
    )

    repeated_after_reset = recovered + [ recoverable.first ]
    repeated_roles = Hive::PlanReview::CheckpointCustody.recoverable_routes(repeated_after_reset)
      .map { |route| route.fetch("role") }
    assert_equal %w[adversarial verification], repeated_roles
  end
end
