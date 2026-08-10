require_relative "../../test_helper"
require "hive/provider_routing"

class ProviderRoutingValueObjectsTest < Minitest::Test
  def test_request_route_and_decision_are_deeply_immutable
    route = Hive::ProviderRouting::Route.new(
      id: "codex-primary/gpt-5.6-sol",
      account: "codex-primary",
      adapter: "codex",
      launch_binding: "default",
      model: "gpt-5.6-sol",
      effort: "high",
      order: 0,
      capabilities: {
        "quality" => "high",
        "context" => "large",
        "tools" => %w[shell filesystem],
        "permissions" => %w[read write]
      },
      model_routing: nil
    )
    policy = Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: [ route ],
      requirements: Hive::ProviderRouting::Requirements.empty,
      pin: nil,
      account_policy: {
        "codex-primary" => {
          "adapter" => "codex",
          "launch_binding" => "default",
          "max_concurrent" => 2
        }
      }
    )
    request = Hive::ProviderRouting::Request.new(
      policy: policy,
      task_generation: "generation-1",
      health: { "codex-primary" => { "state" => "closed" } },
      capacity: { "codex-primary" => { "observed" => 0, "max" => 2 } }
    )
    decision = Hive::ProviderRouting::Decision.selected(
      request: request,
      route: route,
      considered: [ route ],
      exclusions: []
    )

    assert route.frozen?
    assert route.capabilities.frozen?
    assert route.capabilities.fetch("tools").frozen?
    assert request.frozen?
    assert request.health.dig("codex-primary").frozen?
    assert decision.frozen?
    assert decision.considered.frozen?
    assert_equal "codex-primary", decision.account
    assert_equal "codex", decision.adapter
    assert_equal "gpt-5.6-sol", decision.model
    assert_equal policy.digest, decision.policy_digest
  end

  def test_legacy_policy_has_no_digest_or_candidate_identity
    policy = Hive::ProviderRouting::Policy.legacy(stage: "execute")

    assert policy.legacy?
    refute policy.explicit?
    assert_empty policy.routes
    assert_nil policy.digest
    assert_nil policy.decision_id
  end
end
