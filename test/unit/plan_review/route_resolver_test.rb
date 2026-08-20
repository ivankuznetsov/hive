require "test_helper"
require "hive/plan_review/route_resolver"

class PlanReviewRouteResolverTest < Minitest::Test
  include HiveTestHelper

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

  def test_verification_and_unrecognised_roles_default_to_native_codex
    seen = {}
    %w[verification some-new-role].each do |role|
      Hive::PlanReview::RouteResolver.resolve(
        role: role,
        planner_identity: { "provider" => "claude", "family" => "claude" },
        probe: lambda do |value|
          seen[role] = value
          { "status" => "present", "actual" => value }
        end
      )
    end

    seen.each_value do |value|
      assert_equal "codex", value.fetch("provider")
      assert_equal "gpt-5.6-sol", value.fetch("model")
      assert_equal "native_codex", value.fetch("route")
    end
  end

  def test_configured_fallback_rows_are_probed_after_the_primary
    cfg = {
      "plan_review" => {
        "routes" => {
          "adversarial" => {
            "agent" => "grok", "model" => "grok-4.6", "family" => "grok",
            "effort" => "high", "route" => "native_grok_build"
          },
          "fallbacks" => [
            {
              "agent" => "codex", "model" => "gpt-5.6-sol", "family" => "openai",
              "effort" => "medium", "route" => "native_codex"
            }
          ]
        }
      }
    }
    probed = []

    Hive::PlanReview::RouteResolver.resolve(
      role: "adversarial", cfg: cfg,
      planner_identity: { "provider" => "grok", "family" => "grok" },
      probe: lambda do |value|
        probed << value
        # Reject the primary on independence so the fallback row is reached.
        { "status" => "present", "actual" => value }
      end
    )

    assert_equal %w[grok codex], probed.map { |value| value.fetch("provider") }
    assert_equal "medium", probed.last.fetch("effort")
    assert_equal "native_codex", probed.last.fetch("route")
  end

  def test_blank_route_fields_are_rejected_before_probing
    error = assert_raises(Hive::ConfigError) do
      Hive::PlanReview::RouteResolver.resolve(
        role: "adversarial",
        planner_identity: { "provider" => "claude", "family" => "claude" },
        candidates: [ candidate("codex", "  ", "openai") ],
        probe: ->(value) { { "status" => "present", "actual" => value } }
      )
    end

    assert_includes error.message, "plan review route model must be non-empty"
  end

  def test_family_attestation_is_enforced_when_required
    # `resolve` deliberately passes `require_family: false` (an unknown family
    # is downgraded to nil rather than rejected), so this defensive branch has
    # no caller today and is reachable only directly.
    error = assert_raises(Hive::ConfigError) do
      Hive::PlanReview::RouteResolver.send(
        :normalize_candidate, candidate("codex", "gpt-5.6-sol", nil), require_family: true
      )
    end

    assert_includes error.message, "plan review route family must be attested"
  end

  def test_observed_identity_rejects_a_non_string_field
    error = assert_raises(Hive::ConfigError) do
      Hive::PlanReview::RouteResolver.resolve(
        role: "adversarial",
        planner_identity: { "provider" => "claude", "family" => "claude" },
        candidates: [ candidate("codex", "gpt-5.6-sol", "openai") ],
        probe: ->(_value) { { "status" => "present", "actual" => { "provider" => 5 } } }
      )
    end

    assert_includes error.message, "observed plan review route provider must be non-empty"
  end

  # Confinement no longer gates the probe — reviewers need the repo, and the
  # ArtifactFirewall is what guards the protected artifacts. What still
  # refuses a provider is failing to prepare its runtime at all, and the
  # diagnostic must name that real reason rather than a policy verdict.
  def test_default_probe_refuses_a_provider_whose_runtime_cannot_be_prepared
    failure = ->(*) { raise "opencode runtime unavailable" }
    observation = nil
    with_replaced_singleton_method(Hive::AgentRuntime, :prepare!, failure) do
      observation = Hive::PlanReview::RouteResolver.default_probe(
        candidate("opencode", "claude-sonnet-4.5", "anthropic")
      )
    end

    assert_equal "unsupported", observation.fetch("status")
    refute_includes observation.fetch("diagnostic"),
                    "cannot enforce disposable workspace confinement"
    assert_includes observation.fetch("diagnostic"), "opencode"
  end

  private

  def candidate(provider, model, family)
    {
      "provider" => provider, "model" => model, "family" => family,
      "effort" => "high", "route" => "fallback"
    }
  end
end
