require "test_helper"
require "json_schemer"
require "hive/plan_review/record"

class PlanReviewRecordTest < Minitest::Test
  def test_projection_requires_closed_state_outcome_and_execution_invariants
    record = Hive::PlanReview::Record.new(projection)
    assert_equal "cleared", record.state
    assert record.execution_allowed?
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-plan-review"))))
    assert_empty schema.validate(record.to_h).to_a

    assert_raises(Hive::PlanReview::InvalidRecord) do
      Hive::PlanReview::Record.new(projection.merge("state" => "invented"))
    end
    assert_raises(Hive::PlanReview::InvalidRecord) do
      Hive::PlanReview::Record.new(
        projection.merge("state" => "blocked", "outcome" => "blocked", "execution_allowed" => true)
      )
    end
    assert_raises(Hive::PlanReview::InvalidRecord) do
      Hive::PlanReview::Record.new(projection.merge("surprise" => true))
    end
  end

  def test_manifest_and_projection_share_immutable_identity
    manifest = Hive::PlanReview::Record.new(
      projection.slice(*Hive::PlanReview::Record::MANIFEST_KEYS)
                .merge("kind" => "manifest")
    )
    assert_equal projection.fetch("review_id"), manifest.review_id
    assert_equal projection.fetch("policy_fingerprint"), manifest.policy_fingerprint
  end

  private

  def projection
    now = "2026-08-12T12:00:00.000000Z"
    {
      "schema" => "hive-plan-review",
      "schema_version" => 1,
      "kind" => "projection",
      "review_id" => "pr-#{'a' * 64}",
      "prior_review_id" => nil,
      "version" => 1,
      "task_id" => "task-1",
      "task_generation" => "generation-1",
      "plan_digest" => "b" * 64,
      "candidate_plan_digest" => nil,
      "policy_fingerprint" => "c" * 64,
      "computed_level" => "standard",
      "effective_level" => "standard",
      "state" => "cleared",
      "outcome" => "cleared",
      "attempt_ids" => [],
      "current_attempt_id" => nil,
      "coverage" => [],
      "findings" => [],
      "decisions" => [],
      "routes" => [],
      "artifacts" => {},
      "blockers" => [],
      "required_action" => nil,
      "degradation_reason" => nil,
      "execution_allowed" => true,
      "created_at" => now,
      "updated_at" => now
    }
  end
end
