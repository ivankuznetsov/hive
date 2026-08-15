require "test_helper"
require "hive/plan_review/route_resolver"

class PlanReviewRouteResolverTest < Minitest::Test
  def test_adversarial_route_prefers_native_grok_46_and_attests_independence
    observed = nil
    resolution = Hive::PlanReview::RouteResolver.resolve(
      role: "adversarial",
      planner_identity: { "provider" => "claude", "family" => "claude" },
      probe: lambda do |candidate|
        observed = candidate
        {
          "status" => "present",
          "actual" => candidate.merge("family" => "grok", "route" => "native_grok_build")
        }
      end
    )

    assert_equal "grok", observed.fetch("provider")
    assert_equal "grok-4.6", observed.fetch("model")
    assert resolution.resolved?
    assert resolution.receipt.fetch("independence_verified")
  end

  def test_fallback_counts_only_when_attested_family_differs
    same_family = Hive::PlanReview::RouteResolver.resolve(
      role: "adversarial",
      planner_identity: { "provider" => "openai", "family" => "openai" },
      candidates: [ candidate("codex", "gpt-5.6-sol", "openai") ],
      probe: ->(value) { { "status" => "present", "actual" => value } }
    )
    unknown = Hive::PlanReview::RouteResolver.resolve(
      role: "adversarial",
      planner_identity: { "provider" => "openai", "family" => "openai" },
      candidates: [ candidate("custom", "model", nil) ],
      probe: ->(value) { { "status" => "present", "actual" => value } }
    )
    different = Hive::PlanReview::RouteResolver.resolve(
      role: "adversarial",
      planner_identity: { "provider" => "openai", "family" => "openai" },
      candidates: [ candidate("claude", "opus", "claude") ],
      probe: ->(value) { { "status" => "present", "actual" => value } }
    )

    refute same_family.receipt.fetch("independence_verified")
    refute unknown.receipt.fetch("independence_verified")
    assert different.receipt.fetch("independence_verified")
  end

  def test_unavailable_candidates_preserve_requested_and_capability_evidence
    resolution = Hive::PlanReview::RouteResolver.resolve(
      role: "adversarial",
      planner_identity: { "provider" => "claude", "family" => "claude" },
      probe: ->(_candidate) { { "status" => "unsupported", "diagnostic" => "not installed" } }
    )

    refute resolution.resolved?
    assert_equal "grok-4.6", resolution.receipt.dig("requested", "model")
    assert_equal "unsupported", resolution.receipt.fetch("capability_result")
  end

  def test_configured_identity_is_not_credited_when_probe_does_not_observe_model_family
    resolution = Hive::PlanReview::RouteResolver.resolve(
      role: "adversarial",
      planner_identity: { "provider" => "openai", "family" => "openai" },
      candidates: [ candidate("claude", "opus", "anthropic") ],
      probe: lambda do |_candidate|
        { "status" => "present", "actual" => { "provider" => "claude", "route" => "native" } }
      end
    )

    refute resolution.receipt.fetch("independence_verified")
    assert_equal "reviewer_family_unknown", resolution.receipt.fetch("independence_reason")
    refute resolution.receipt.fetch("actual").key?("model")
    assert_equal "opus", resolution.candidate.fetch("model")
  end

  def test_present_non_independent_candidate_does_not_hide_independent_fallback
    candidates = [
      candidate("codex", "gpt-5.6-sol", "openai"),
      candidate("claude", "opus", "anthropic")
    ]
    resolution = Hive::PlanReview::RouteResolver.resolve(
      role: "adversarial",
      planner_identity: { "provider" => "openai", "family" => "openai" },
      candidates:,
      probe: ->(value) { { "status" => "present", "actual" => value } }
    )

    assert_equal "claude", resolution.candidate.fetch("provider")
    assert resolution.receipt.fetch("independence_verified")
    assert_equal 2, resolution.receipt.fetch("attempts").length
    assert_equal "codex", resolution.receipt.dig("requested", "provider")
  end

  def test_non_independent_fallback_receipt_keeps_every_probe_attempt
    candidates = [
      candidate("codex", "gpt-5.6-sol", "openai"),
      candidate("grok", "grok-4.6", "grok")
    ]
    resolution = Hive::PlanReview::RouteResolver.resolve(
      role: "adversarial", planner_identity: { "family" => "openai" }, candidates:,
      probe: lambda do |value|
        if value.fetch("provider") == "codex"
          { "status" => "present", "actual" => value }
        else
          { "status" => "unsupported", "diagnostic" => "missing" }
        end
      end
    )

    refute resolution.receipt.fetch("independence_verified")
    assert_equal %w[present unsupported], resolution.receipt.fetch("attempts").map { |row|
      row.fetch("status")
    }
  end

  def test_project_model_routing_overrides_the_configured_role_without_switching_provider
    cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS)).merge(
      "models" => { "plan_review_adversarial" => { "model" => "grok-4.6-fast", "effort" => "xhigh" } }
    )
    observed = nil
    Hive::PlanReview::RouteResolver.resolve(
      role: "adversarial",
      planner_identity: { "family" => "claude" },
      cfg:,
      probe: lambda do |candidate|
        observed = candidate
        { "status" => "present", "actual" => candidate }
      end
    )

    assert_equal "grok", observed.fetch("provider")
    assert_equal "grok-4.6-fast", observed.fetch("model")
    assert_equal "xhigh", observed.fetch("effort")
  end

  def test_primary_verification_and_configured_fallback_candidates_are_exact
    %w[primary verification].each do |role|
      observed = nil
      Hive::PlanReview::RouteResolver.resolve(
        role:, planner_identity: { "family" => "anthropic" },
        probe: lambda do |candidate|
          observed = candidate
          { "status" => "present", "actual" => candidate }
        end
      )
      assert_equal "codex", observed.fetch("provider")
      assert_equal "gpt-5.6-sol", observed.fetch("model")
    end

    cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    cfg["plan_review"]["routes"]["fallbacks"] = [
      {
        "agent" => "claude", "model" => "opus", "family" => "anthropic",
        "effort" => "high", "route" => "fallback-claude"
      }
    ]
    attempts = []
    result = Hive::PlanReview::RouteResolver.resolve(
      role: "adversarial", planner_identity: { "family" => "anthropic" }, cfg:,
      probe: lambda do |candidate|
        attempts << candidate
        if candidate.fetch("provider") == "grok"
          { "status" => "unsupported" }
        else
          { "status" => "present", "actual" => candidate }
        end
      end
    )
    assert result.resolved?
    assert_equal "fallback-claude", attempts.last.fetch("route")
  end

  def test_malformed_requested_and_observed_route_fields_fail_closed
    invalid = candidate("codex", "", "openai")
    assert_raises(Hive::ConfigError) do
      Hive::PlanReview::RouteResolver.resolve(
        role: "primary", planner_identity: { "family" => "anthropic" },
        candidates: [ invalid ], probe: ->(_candidate) { flunk }
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::PlanReview::RouteResolver.send(
        :normalize_candidate, candidate("codex", "model", nil), require_family: true
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::PlanReview::RouteResolver.resolve(
        role: "primary", planner_identity: { "family" => "anthropic" },
        candidates: [ candidate("codex", "model", "openai") ],
        probe: ->(_candidate) { { "status" => "present", "actual" => { "provider" => 1 } } }
      )
    end
  end

  private

  def candidate(provider, model, family)
    {
      "provider" => provider, "model" => model, "family" => family,
      "effort" => "high", "route" => "fallback"
    }
  end
end
