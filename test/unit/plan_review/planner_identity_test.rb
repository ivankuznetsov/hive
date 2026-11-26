require "test_helper"
require "hive/plan_review/planner_identity"
require "hive/plan_review/route_resolver"

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
  def test_muse_planner_has_a_family_so_a_codex_adversary_is_independent
    profile = Hive::AgentProfiles.lookup(:muse)
    cfg = Hive::Config::DEFAULTS.merge(
      "plan" => Hive::Config::DEFAULTS.fetch("plan").merge(
        "agent" => "muse", "model" => "muse-wonder-full-1.0", "effort" => "xhigh"
      )
    )

    identity = Hive::PlanReview::PlannerIdentity.capture(profile:, cfg:)

    assert_equal "meta", identity.fetch("family")
    assert_equal "muse-code/v1", identity.fetch("route")
    assert_equal [ true, "different_model_family" ],
                 Hive::PlanReview::RouteResolver.independence(identity, { "family" => "openai" })
    assert_equal [ false, "same_model_family" ],
                 Hive::PlanReview::RouteResolver.independence(identity, { "family" => "meta" })
  end

  def test_agy_planner_has_a_family_so_a_codex_adversary_is_independent
    profile = Hive::AgentProfiles.lookup(:agy)
    cfg = Hive::Config::DEFAULTS.merge(
      "plan" => Hive::Config::DEFAULTS.fetch("plan").merge(
        "agent" => "agy", "model" => "gemini-4-neon-xhigh", "effort" => "xhigh"
      )
    )

    identity = Hive::PlanReview::PlannerIdentity.capture(profile:, cfg:, observed_model: "gemini-4-neon-xhigh")
    silent = Hive::PlanReview::PlannerIdentity.capture(profile:, cfg:)
    assert_nil silent.fetch("family")

    assert_equal "google", identity.fetch("family")
    assert_equal "antigravity-cli/v1", identity.fetch("route")
    claude = Hive::PlanReview::PlannerIdentity.capture(profile:, cfg:, observed_model: "claude-opus-5-5-high")
    assert_equal "anthropic", claude.fetch("family")
    legacy = claude.merge("family" => "google")
    assert_equal [ false, "planner_family_unknown" ],
                 Hive::PlanReview::RouteResolver.independence(legacy, { "family" => "anthropic" })
    unknown = Hive::PlanReview::PlannerIdentity.capture(profile:, cfg:, observed_model: "custom-model")
    assert_nil unknown.fetch("family")
    assert_equal [ true, "different_model_family" ],
                 Hive::PlanReview::RouteResolver.independence(identity, { "family" => "openai" })
    assert_equal [ false, "same_model_family" ],
                 Hive::PlanReview::RouteResolver.independence(identity, { "family" => "google" })
  end
end
