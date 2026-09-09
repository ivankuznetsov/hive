require_relative "../../test_helper"
require "hive/provider_routing/router"

class ProviderRoutingRouterTest < Minitest::Test
  NOW = Time.utc(2026, 8, 10, 12)

  def test_new_work_selects_the_first_eligible_configured_route
    decision = route(capacity: capacity("account-a" => 0, "account-b" => 0))

    assert decision.selected?
    assert_equal "account-a/model-a", decision.route.id
    assert_equal %w[account-a/model-a account-b/model-b],
                 decision.candidates.map { |candidate| candidate.route.id }
    assert_empty decision.exclusions
  end

  def test_provider_retry_starts_after_the_failed_route_and_wraps_once
    after_a = route(
      capacity: capacity("account-a" => 0, "account-b" => 0),
      failed_route_id: "account-a/model-a"
    )
    after_b = route(
      capacity: capacity("account-a" => 0, "account-b" => 0),
      failed_route_id: "account-b/model-b"
    )

    assert_equal "account-b/model-b", after_a.route.id
    assert_equal %w[account-b/model-b account-a/model-a],
                 after_a.candidates.map { |candidate| candidate.route.id }
    assert_equal [ "failed_route" ], after_a.exclusions.map(&:reason)
    assert_equal "account-a/model-a", after_b.route.id
    assert_equal %w[account-a/model-a account-b/model-b],
                 after_b.candidates.map { |candidate| candidate.route.id }
    assert_equal [ "failed_route" ], after_b.exclusions.map(&:reason)
  end

  def test_retry_uses_current_pool_order_and_restarts_when_failed_route_is_missing
    reordered = policy(routes: [
      build_route("account-b", "model-b", "claude", "team-b", 0),
      build_route("account-a", "model-a", "codex", "team-a", 1)
    ])
    after_a = route(
      policy: reordered,
      capacity: capacity("account-a" => 0, "account-b" => 0),
      failed_route_id: "account-a/model-a"
    )
    missing = route(
      policy: reordered,
      capacity: capacity("account-a" => 0, "account-b" => 0),
      failed_route_id: "removed/model"
    )

    assert_equal "account-b/model-b", after_a.route.id
    assert_equal "account-b/model-b", missing.route.id
    assert_empty missing.exclusions
  end

  def test_retry_does_not_reselect_the_only_failed_route
    only_a = policy(routes: [ build_route("account-a", "model-a", "codex", "team-a", 0) ])
    decision = route(
      policy: only_a,
      capacity: capacity("account-a" => 0),
      failed_route_id: "account-a/model-a"
    )

    assert_equal :no_route, decision.status
    assert_equal "no_eligible_provider_route", decision.reason
    assert_equal [ "failed_route" ], decision.exclusions.map(&:reason)
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

  def test_requirements_and_hard_pin_remain_hard_filters
    strict_policy = policy(
      requirements: Hive::ProviderRouting::Requirements.new(tools: %w[browser])
    )
    strict = route(
      policy: strict_policy,
      capacity: capacity("account-a" => 0, "account-b" => 0)
    )
    pinned_policy = policy(pin: Hive::ProviderRouting::Pin.new(provider: "account-b"))
    pinned = route(
      policy: pinned_policy,
      capacity: capacity("account-a" => 0, "account-b" => 0)
    )
    failed_pin = route(
      policy: pinned_policy,
      capacity: capacity("account-a" => 0, "account-b" => 0),
      failed_route_id: "account-b/model-b"
    )

    assert_equal %w[requirements_incompatible requirements_incompatible],
                 strict.exclusions.map(&:reason)
    assert_equal "account-b/model-b", pinned.route.id
    assert_equal [ "hard_pin_mismatch" ], pinned.exclusions.map(&:reason)
    assert_equal :no_route, failed_pin.status
    assert_equal %w[hard_pin_mismatch failed_route], failed_pin.exclusions.map(&:reason)
  end

  def test_missing_capacity_fails_closed_and_empty_pool_returns_no_route
    unavailable = route(capacity: {})
    empty = route(policy: policy(routes: []), capacity: {})

    assert_equal :no_route, unavailable.status
    assert_equal [ "provider_capacity_unavailable" ], unavailable.exclusions.map(&:reason).uniq
    assert_equal :no_route, empty.status
    assert_equal "no_eligible_provider_route", empty.reason
    assert_empty empty.candidates
  end

  def test_replay_is_deterministic_for_the_same_current_inputs
    request = request_for(capacity: capacity("account-a" => 0, "account-b" => 0))
    router = Hive::ProviderRouting::Router.new

    first = router.call(request: request, decision_id: "decision-1", decided_at: NOW)
    replay = router.call(request: request, decision_id: "decision-1", decided_at: NOW)

    assert_equal first.to_h, replay.to_h
    assert_raises(ArgumentError) { router.call(request: Object.new) }
  end

  private

  def route(capacity:, policy: self.policy, failed_route_id: nil)
    Hive::ProviderRouting::Router.new.call(
      request: request_for(
        policy: policy, capacity: capacity, failed_route_id: failed_route_id
      ),
      decision_id: "decision-1",
      decided_at: NOW
    )
  end

  def request_for(capacity:, policy: self.policy, failed_route_id: nil)
    Hive::ProviderRouting::Request.new(
      policy: policy,
      task_generation: "generation-1",
      capacity: capacity,
      failed_route_id: failed_route_id
    )
  end

  def capacity(values)
    values.to_h { |account, observed| [ account, { "observed" => observed, "max" => 1 } ] }
  end

  def policy(routes: nil, requirements: Hive::ProviderRouting::Requirements.empty, pin: nil)
    routes ||= [
      build_route("account-a", "model-a", "codex", "team-a", 0),
      build_route("account-b", "model-b", "claude", "team-b", 1)
    ]
    account_policy = routes.map(&:account).uniq.to_h do |account_id|
      route = routes.find { |candidate| candidate.account == account_id }
      [ account_id, account(route.adapter, route.launch_binding, route.model) ]
    end
    Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: routes,
      requirements: requirements,
      pin: pin,
      account_policy: account_policy
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
      "max_concurrent" => 1
    }
  end
end
