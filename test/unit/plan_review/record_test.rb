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

  def test_projection_rejects_untyped_decisions_and_unbound_coverage
    assert_raises(Hive::PlanReview::InvalidRecord) do
      Hive::PlanReview::Record.new(
        projection.merge(
          "decisions" => [
            { "decision_id" => "prd-#{'d' * 64}", "action" => "approve_finding",
              "target_fingerprint" => "prf-#{'e' * 64}" }
          ]
        )
      )
    end
    assert_raises(Hive::PlanReview::InvalidRecord) do
      Hive::PlanReview::Record.new(
        projection.merge(
          "coverage" => [
            { "name" => "adversarial", "required" => true, "status" => "completed" }
          ]
        )
      )
    end
  end

  def test_projection_nested_state_is_immutable
    value = Hive::PlanReview::Record.new(
      projection.merge("routes" => [ { "role" => "primary" } ])
    )

    assert_predicate value["routes"], :frozen?
    assert_predicate value["routes"].first, :frozen?
    assert_raises(FrozenError) { value["routes"] << { "role" => "adversarial" } }
    assert_raises(FrozenError) { value["routes"].first["role"] = "verification" }
  end

  def test_projection_rejects_wrong_identifier_prefixes_and_degradation_reason
    [
      projection.merge("review_id" => "pra-#{'a' * 64}"),
      projection.merge("prior_review_id" => "prd-#{'a' * 64}"),
      projection.merge(
        "state" => "reviewing", "outcome" => nil, "execution_allowed" => false,
        "attempt_ids" => [ "pr-#{'e' * 64}" ],
        "current_attempt_id" => "pr-#{'e' * 64}"
      ),
      projection.merge("degradation_reason" => "invented")
    ].each do |value|
      assert_raises(Hive::PlanReview::InvalidRecord) do
        Hive::PlanReview::Record.new(value)
      end
    end
  end

  def test_rejects_records_that_cannot_round_trip_through_json
    error = assert_raises(Hive::PlanReview::InvalidRecord) do
      Hive::PlanReview::Record.new(projection.merge("routes" => [ Float::NAN ]))
    end

    assert_match(/not JSON-safe/, error.message)
  end

  def test_rejects_malformed_envelope_and_identity
    {
      /invalid plan review schema envelope/ => { "schema" => "hive-plan" },
      /kind must be one of/ => { "kind" => "invented" },
      /task_id must be non-empty/ => { "task_id" => "" },
      /task_generation must be non-empty/ => { "task_generation" => "" },
      /computed_level/ => { "computed_level" => "invented" },
      /created_at must be ISO-8601/ => { "created_at" => "whenever" }
    }.each do |message, overrides|
      error = assert_raises(Hive::PlanReview::InvalidRecord) do
        Hive::PlanReview::Record.new(projection.merge(overrides))
      end
      assert_match message, error.message
    end
  end

  def test_rejects_malformed_projection_version_digest_and_outcome
    {
      /projection version must be positive/ => { "version" => 0 },
      /candidate plan digest must be SHA-256/ => { "candidate_plan_digest" => "later" },
      /unknown plan review outcome/ => { "outcome" => "invented" },
      /blockers must be an Array/ => { "blockers" => "none" },
      /policy_reasons must be an Array/ => { "policy_reasons" => "because" },
      /level_sources must be a mapping/ => { "level_sources" => [] }
    }.each do |message, overrides|
      error = assert_raises(Hive::PlanReview::InvalidRecord) do
        Hive::PlanReview::Record.new(projection.merge(overrides))
      end
      assert_match message, error.message
    end
  end

  def test_current_attempt_must_belong_to_the_recorded_attempts
    error = assert_raises(Hive::PlanReview::InvalidRecord) do
      Hive::PlanReview::Record.new(
        projection.merge(
          "attempt_ids" => [ "pra-#{'e' * 64}" ],
          "current_attempt_id" => "pra-#{'f' * 64}"
        )
      )
    end

    assert_match(/current attempt must belong to attempt_ids/, error.message)
  end

  def test_coverage_entries_are_bound_to_their_review_and_waiver_decision
    assert Hive::PlanReview::Record.new(
      projection.merge("coverage" => [ coverage_entry("retry_at" => "2026-08-12T13:00:00Z") ])
    )

    {
      /invalid plan review coverage entry/ => coverage_entry("status" => "invented"),
      /coverage retry_at must be ISO-8601/ => coverage_entry("retry_at" => "soon"),
      /coverage decision id is malformed/ => coverage_entry("decision_id" => "nope"),
      /waived plan review coverage requires a decision id/ =>
        coverage_entry("status" => "waived", "decision_id" => nil)
    }.each do |message, entry|
      error = assert_raises(Hive::PlanReview::InvalidRecord) do
        Hive::PlanReview::Record.new(projection.merge("coverage" => [ entry ]))
      end
      assert_match message, error.message
    end
  end

  def test_rejects_artifact_references_without_a_verifiable_digest
    error = assert_raises(Hive::PlanReview::InvalidRecord) do
      Hive::PlanReview::Record.new(
        projection.merge("artifacts" => { "prompt" => { "path" => "prompt.md" } })
      )
    end

    assert_match(/invalid plan review artifact reference/, error.message)
  end

  private

  def coverage_entry(overrides = {})
    {
      "name" => "adversarial", "required" => true, "status" => "completed",
      "fingerprint" => Hive::PlanReview::Identity.coverage(
        review_id: projection.fetch("review_id"),
        name: "adversarial",
        policy_fingerprint: projection.fetch("policy_fingerprint")
      )
    }.merge(overrides)
  end

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
