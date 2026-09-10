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
end
