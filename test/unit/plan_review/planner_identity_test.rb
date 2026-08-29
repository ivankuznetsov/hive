require "test_helper"
require "hive/plan_review/planner_identity"

class PlanReviewPlannerIdentityTest < Minitest::Test
  def test_codex_capture_does_not_inherit_claude_model_controls
    profile = Hive::AgentProfiles.lookup(:codex)
    cfg = Hive::Config::DEFAULTS.merge(
      "plan" => Hive::Config::DEFAULTS.fetch("plan").merge("agent" => "codex"),
      "claude" => Hive::Config::DEFAULTS.fetch("claude").merge(
        "model" => "claude-opus-4-8", "effort" => "high"
      )
    )

    identity = Hive::PlanReview::PlannerIdentity.capture(profile:, cfg:)

    assert_equal "codex", identity.fetch("provider")
    assert_equal "default", identity.fetch("model")
    assert_equal "default", identity.fetch("effort")
    assert_equal "openai", identity.fetch("family")
  end

  def test_repairs_only_the_legacy_codex_claude_model_pair
    legacy = {
      "provider" => "codex", "model" => "claude-opus-4-8",
      "family" => "openai", "effort" => "unknown", "route" => "codex-cli/v1"
    }

    repaired = Hive::PlanReview::PlannerIdentity.repair(
      legacy, cfg: Hive::Config::DEFAULTS
    )

    assert_equal "codex", repaired.fetch("provider")
    assert_equal "default", repaired.fetch("model")
    assert_equal "default", repaired.fetch("effort")
    assert_equal true, repaired.fetch("reconstructed")
    refute Hive::PlanReview::PlannerIdentity.recoverable?(repaired)
    assert_nil Hive::PlanReview::PlannerIdentity.repair(
      legacy.merge("model" => "gpt-5.6-sol"), cfg: Hive::Config::DEFAULTS
    )
  end
end
