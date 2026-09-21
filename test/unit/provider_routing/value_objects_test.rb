require_relative "../../test_helper"
require "json"
require "open3"
require "rbconfig"
require "hive/provider_routing"

class ProviderRoutingValueObjectsTest < Minitest::Test
  def test_public_entrypoint_does_not_expose_retired_provider_state
    lib = File.expand_path("../../../lib", __dir__)
    script = <<~'RUBY'
      require "json"
      require "hive/provider_routing"
      puts JSON.generate(
        "policy_repository" => Hive::ProviderRouting.const_defined?(:PolicyRepository, false),
        "operational_projection" => Hive::ProviderRouting.const_defined?(:OperationalProjection, false),
        "provider_health" => Hive.const_defined?(:ProviderHealth, false)
      )
    RUBY
    out, err, status = Open3.capture3(
      { "RUBYOPT" => nil },
      RbConfig.ruby,
      "-I#{lib}",
      "-e",
      script
    )

    assert status.success?, err
    payload = JSON.parse(out)
    assert_equal false, payload.fetch("policy_repository")
    assert_equal false, payload.fetch("operational_projection")
    assert_equal false, payload.fetch("provider_health")
  end

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
      capacity: { "codex-primary" => { "observed" => 0, "max" => 2 } },
      failed_route_id: "previous/route"
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
    assert request.capacity.dig("codex-primary").frozen?
    assert_equal "previous/route", request.failed_route_id
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
    assert_equal "hive-provider-routing-policy/v1", policy.to_h.fetch("schema")
  end

  def test_request_decision_and_canonical_values_reject_invalid_inputs
    assert_equal %({"kind":"probe"}), Hive::ProviderRouting.canonical_json(kind: :probe)
    assert_equal({ "tools" => [], "permissions" => [] },
                 Hive::ProviderRouting.profile_capability_limits("future-agent"))
    assert_raises(ArgumentError) do
      Hive::ProviderRouting::Request.new(policy: Object.new, task_generation: "generation-1")
    end
    assert_raises(ArgumentError) do
      Hive::ProviderRouting::Decision.selected(
        request: Object.new, route: nil, considered: []
      )
    end

    policy = Hive::ProviderRouting::Policy.legacy(stage: "execute")
    request = Hive::ProviderRouting::Request.new(
      policy: policy, task_generation: "generation-1"
    )
    assert_raises(ArgumentError) do
      Hive::ProviderRouting::Decision.legacy(request: request).send(
        :normalize_time, "not-a-time"
      )
    end

    account_args = {
      id: "codex-primary", adapter: "codex", launch_binding: "default",
      models: [ "gpt-5.6-sol" ], max_concurrent: 1, cooldown_sec: {}
    }
    assert_raises(ArgumentError) do
      Hive::ProviderRouting::Account.new(**account_args, billing_route: "invoice")
    end
    assert_raises(ArgumentError) do
      Hive::ProviderRouting::Account.new(
        **account_args, billing_evidence_source: "log_guess"
      )
    end

    route_args = {
      id: "codex-primary/gpt-5.6-sol", account: "codex-primary",
      adapter: "codex", launch_binding: "default", model: "gpt-5.6-sol",
      effort: nil, order: 0, capabilities: {}
    }
    assert_raises(ArgumentError) do
      Hive::ProviderRouting::Route.new(**route_args, billing_route: "invoice")
    end
    assert_raises(ArgumentError) do
      Hive::ProviderRouting::Route.new(
        **route_args, billing_evidence_source: "log_guess"
      )
    end
  end
end
