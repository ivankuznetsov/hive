require_relative "../../test_helper"
require "hive/provider_health/store"
require "hive/provider_routing/router"

class ProviderRoutingRouterTest < Minitest::Test
  NOW = Time.utc(2026, 8, 10, 12)

  def setup
    @root = Dir.mktmpdir("provider-router")
    @health = Hive::ProviderHealth::Store.new(
      root: File.join(@root, "health"),
      clock: -> { NOW }
    )
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_selects_first_healthy_unsaturated_route_and_explains_fallback
    @health.block(
      scope: Hive::ProviderHealth::Scope.provider_account(account_id: "account-a"),
      expected_generation: 0,
      actor: "uid:1000",
      reason: "account maintenance"
    )
    decision = route(capacity: capacity("account-a" => 0, "account-b" => 0))

    assert decision.selected?
    assert_equal "account-b/model-b", decision.route.id
    assert_equal %w[account-a/model-a account-b/model-b],
                 decision.candidates.map { |candidate| candidate.route.id }
    assert_equal [ "manual_block" ], decision.exclusions.map(&:reason)
    assert_equal "attempt", decision.next_action_owner
    assert_equal 2, decision.circuit_generations.length
  end

  def test_skips_a_saturated_account_and_classifies_all_capacity_as_scheduler_owned
    fallback = route(capacity: capacity("account-a" => 1, "account-b" => 0))
    saturated = route(capacity: capacity("account-a" => 1, "account-b" => 1))

    assert_equal "account-b/model-b", fallback.route.id
    assert_equal [ "provider_concurrency_saturated" ], fallback.exclusions.map(&:reason)
    assert saturated.capacity_saturated?
    assert_equal "capacity_saturated", saturated.reason
    assert_equal "scheduler", saturated.next_action_owner
    assert_equal [ 1, 1 ], saturated.candidates.map(&:observed_concurrency)
  end

  def test_health_unavailability_fails_closed_with_operator_owner
    evaluation = @health.evaluate_route(account_id: "account-a", model_id: "model-a")
    unavailable = Hive::ProviderHealth::RouteEvaluation.new(
      status: "excluded",
      inspections: evaluation.inspections,
      blockers: [
        {
          "scope" => evaluation.inspections.first.scope.to_h,
          "reason" => "health_state_unavailable",
          "generation" => 0,
          "journal_epoch" => 0
        }
      ],
      probe_requirements: []
    )
    request = request_for(
      health: {
        "account-a/model-a" => unavailable,
        "account-b/model-b" => unavailable
      },
      capacity: capacity("account-a" => 0, "account-b" => 0)
    )

    decision = Hive::ProviderRouting::Router.new.call(
      request: request,
      decision_id: "decision-unavailable",
      decided_at: NOW
    )

    assert_equal :no_route, decision.status
    assert_equal "health_state_unavailable", decision.reason
    assert_equal "operator", decision.next_action_owner
  end

  def test_replay_is_deterministic_for_supplied_identity_and_observation_time
    request = request_for(
      health: health_evaluations,
      capacity: capacity("account-a" => 0, "account-b" => 0)
    )
    router = Hive::ProviderRouting::Router.new

    first = router.call(request: request, decision_id: "decision-1", decided_at: NOW)
    replay = router.call(request: request, decision_id: "decision-1", decided_at: NOW)

    assert_equal first.to_h, replay.to_h
  end

  private

  def route(capacity:)
    Hive::ProviderRouting::Router.new.call(
      request: request_for(health: health_evaluations, capacity: capacity),
      decision_id: "decision-1",
      decided_at: NOW
    )
  end

  def request_for(health:, capacity:)
    Hive::ProviderRouting::Request.new(
      policy: policy,
      task_generation: "generation-1",
      health: health,
      capacity: capacity
    )
  end

  def health_evaluations
    policy.routes.to_h do |route|
      [ route.id, @health.evaluate_route(account_id: route.account, model_id: route.model, now: NOW) ]
    end
  end

  def capacity(values)
    values.to_h { |account, observed| [ account, { "observed" => observed, "max" => 1 } ] }
  end

  def policy
    @policy ||= Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: [
        build_route("account-a", "model-a", "codex", "team-a", 0),
        build_route("account-b", "model-b", "claude", "team-b", 1)
      ],
      requirements: Hive::ProviderRouting::Requirements.empty,
      pin: nil,
      account_policy: {
        "account-a" => account("codex", "team-a", "model-a"),
        "account-b" => account("claude", "team-b", "model-b")
      }
    )
  end

  def build_route(account_id, model, adapter, binding, order)
    Hive::ProviderRouting::Route.new(
      id: "#{account_id}/#{model}",
      account: account_id,
      adapter: adapter,
      launch_binding: binding,
      model: model,
      effort: "high",
      order: order,
      capabilities: {
        "context" => "large", "quality" => "high",
        "tools" => %w[shell], "permissions" => %w[read]
      }
    )
  end

  def account(adapter, binding, model)
    {
      "adapter" => adapter,
      "launch_binding" => binding,
      "models" => [ model ],
      "max_concurrent" => 1,
      "cooldown_sec" => Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
    }
  end
end
