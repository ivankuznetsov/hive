require "test_helper"
require "hive/plan_review/policy"

class PlanReviewPolicyTest < Minitest::Test
  FakeSignals = Data.define(:skip_eligible?, :mandatory_reasons, :evidence, :plan_path) do
    def to_h
      {
        "skip_eligible" => skip_eligible?,
        "mandatory_reasons" => mandatory_reasons,
        "evidence" => evidence,
        "plan_path" => plan_path
      }
    end
  end

  def test_non_coding_workflows_are_not_applicable
    result = Hive::PlanReview::Policy.evaluate(
      workflow_id: "research", signals: signals(skip: true), config: config
    )

    refute result.applicable?
    assert_nil result.computed_level
    assert_nil result.effective_level
  end

  def test_skip_requires_affirmative_signals_and_uncertainty_defaults_standard
    skip = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: signals(skip: true), config: config
    )
    ordinary = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: signals(skip: false), config: config
    )

    assert_equal "skip", skip.computed_level
    assert_equal "skip", skip.effective_level
    assert_equal "standard", ordinary.computed_level
    assert_equal "standard", ordinary.effective_level
  end

  def test_any_mandatory_reason_requires_mandatory_review
    result = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding",
      signals: signals(
        skip: true,
        mandatory: [ { "category" => "auth_secrets_permissions", "evidence" => "auth" } ]
      ),
      config: config
    )

    assert_equal "mandatory", result.computed_level
    assert_equal "mandatory", result.effective_level
    assert_equal [ "auth_secrets_permissions" ], result.matched_reasons.map { |r| r["category"] }
  end

  def test_project_workflow_and_run_levels_only_raise
    project_raise = config.merge("minimum_level" => "standard")
    result = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding",
      signals: signals(skip: true),
      config: project_raise,
      run_level: "mandatory"
    )

    assert_equal "skip", result.computed_level
    assert_equal "mandatory", result.effective_level
    assert_equal "mandatory", result.level_sources.fetch("run")

    error = assert_raises(Hive::ConfigError) do
      Hive::PlanReview::Policy.evaluate(
        workflow_id: "coding",
        signals: signals(skip: false),
        config: config,
        run_level: "skip"
      )
    end
    assert_match(/run review level cannot lower/i, error.message)
  end

  def test_fingerprint_is_stable_for_equivalent_inputs_and_changes_materially
    a = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: signals(skip: false), config: config
    )
    b = Hive::PlanReview::Policy.evaluate(
      workflow_id: :coding, signals: signals(skip: false), config: config.dup
    )
    c = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding",
      signals: signals(skip: false, evidence: { "declared_files" => [ "lib/changed.rb" ] }),
      config: config
    )

    assert_equal a.policy_fingerprint, b.policy_fingerprint
    refute_equal a.policy_fingerprint, c.policy_fingerprint
    assert_match(/\A[0-9a-f]{64}\z/, a.policy_fingerprint)
  end

  def test_fingerprint_does_not_change_when_the_task_folder_moves_between_stages
    plan = signals(skip: false, plan_path: "/tmp/project/.hive-state/stages/3-plan/demo/plan.md")
    moved = signals(skip: false, plan_path: "/tmp/project/.hive-state/stages/4-execute/demo/plan.md")

    first = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: plan, config: config
    )
    second = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: moved, config: config
    )

    assert_equal first.policy_fingerprint, second.policy_fingerprint
  end

  private

  def config
    {
      "enabled" => true,
      "minimum_level" => "skip",
      "coding" => { "minimum_level" => "skip" },
      "classifier_version" => 1,
      "skip" => { "max_files" => 5, "max_bytes" => 262_144 },
      "protected_paths" => []
    }
  end

  def signals(skip:, mandatory: [], evidence: {}, plan_path: "/tmp/plan.md")
    FakeSignals.new(
      skip_eligible?: skip,
      mandatory_reasons: mandatory,
      evidence: { "declared_files" => [ "lib/example.rb" ] }.merge(evidence),
      plan_path:
    )
  end
end
