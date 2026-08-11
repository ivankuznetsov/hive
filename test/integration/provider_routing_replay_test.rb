require_relative "../test_helper"
require "digest"
require "hive/provider_health/store"
require "hive/provider_routing/router"

class ProviderRoutingReplayTest < Minitest::Test
  NOW = Time.utc(2026, 8, 10, 12)
  DECIDED_AT = Time.utc(2026, 8, 10, 12, 0, 1)

  def setup
    @root = Dir.mktmpdir("provider-routing-replay")
    @attempts = {}
    @health = health_store
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_ae1_and_ae3_failure_falls_back_and_replays_identically_after_restart
    initial = decide(policy: policy, decision_id: "initial")
    evidence, attempt, receipt = open_scope(
      provider_scope("account-a"),
      failure_class: "account_quota",
      attempt_id: "attempt-a"
    )

    duplicate = @health.apply_evidence(
      evidence: evidence,
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )
    after_failure = decide(policy: policy, decision_id: "fallback")
    restarted = health_store
    replay = decide(policy: policy, decision_id: "fallback", store: restarted)

    assert_equal "account-a/model-a", initial.route.id
    assert duplicate.duplicate?
    assert_equal 1, restarted.inspect_scope(provider_scope("account-a")).generation
    assert_equal "account-b/model-b", after_failure.route.id
    assert_equal %w[circuit_open circuit_cooldown], after_failure.exclusions.map(&:reason)
    assert_equal after_failure.to_h, replay.to_h
  end

  def test_ae4_strict_pin_reports_each_required_exclusion_without_crossing_boundary
    %w[
      circuit_cooldown manual_block requirements_incompatible
      half_open_probe_owned provider_concurrency_saturated
    ].each do |reason|
      @health = health_store(root_suffix: reason)
      pinned = pinned_policy_for(reason)
      decision = decide(
        policy: pinned,
        decision_id: "strict-pin-#{reason}",
        capacity: reason == "provider_concurrency_saturated" ?
          capacity("account-a" => 1) : capacity
      )

      refute decision.selected?, reason
      assert_equal "no_eligible_provider_route", decision.reason, reason
      pinned_candidate = decision.candidates.find { |candidate| candidate.route.account == "account-a" }
      expected = reason == "circuit_cooldown" ? %w[circuit_open circuit_cooldown] : [ reason ]
      assert_equal expected, pinned_candidate.exclusions.map(&:reason), reason
      assert_includes(
        decision.candidates.find { |candidate| candidate.route.account == "account-b" }
          .exclusions.map(&:reason),
        "hard_pin_mismatch",
        reason
      )
    end
  end

  def test_ae5_partial_capacity_falls_through_and_total_capacity_is_neutral
    generations = all_scopes.map { |scope| @health.inspect_scope(scope).generation }
    partial = decide(
      policy: policy,
      decision_id: "partial-capacity",
      capacity: capacity("account-a" => 1, "account-b" => 0)
    )
    saturated = decide(
      policy: policy,
      decision_id: "total-capacity",
      capacity: capacity("account-a" => 1, "account-b" => 1)
    )

    assert_equal "account-b/model-b", partial.route.id
    assert_equal [ "provider_concurrency_saturated" ], partial.exclusions.map(&:reason)
    assert saturated.capacity_saturated?
    assert_equal "capacity_saturated", saturated.reason
    assert_equal "scheduler", saturated.next_action_owner
    assert_equal generations,
                 all_scopes.map { |scope| @health.inspect_scope(scope).generation }
  end

  def test_ae7_operator_mutations_compose_without_erasing_other_scope
    open_scope(
      model_scope("account-a", "model-a"),
      failure_class: "model_capacity",
      attempt_id: "attempt-model"
    )
    blocked = @health.block(
      scope: provider_scope("account-a"),
      expected_generation: 0,
      actor: "uid:1000",
      reason: "planned account maintenance"
    )
    unblocked = @health.unblock(
      scope: provider_scope("account-a"),
      expected_generation: blocked.generation,
      actor: "uid:1000",
      reason: "account maintenance complete"
    )

    evaluation = @health.evaluate_route(
      account_id: "account-a", model_id: "model-a", now: NOW
    )

    assert_equal 2, unblocked.generation
    refute @health.inspect_scope(provider_scope("account-a")).circuit.blocked?
    assert_equal "open",
                 @health.inspect_scope(model_scope("account-a", "model-a")).circuit.automatic_state
    assert_equal %w[circuit_open circuit_cooldown],
                 evaluation.blockers.map { |entry| entry.fetch("reason") }
  end

  def test_ae8_legacy_bypasses_health_while_explicit_one_route_is_excludable
    @health.block(
      scope: provider_scope("account-a"),
      expected_generation: 0,
      actor: "uid:1000",
      reason: "planned maintenance"
    )
    legacy = Hive::ProviderRouting::Router.new.call(
      request: Hive::ProviderRouting::Request.new(
        policy: Hive::ProviderRouting::Policy.legacy(stage: "execute"),
        task_generation: "generation-legacy"
      )
    )
    one_route = policy(routes: [ routes.first ], accounts: [ "account-a" ])
    explicit = decide(policy: one_route, decision_id: "explicit-one")

    assert legacy.legacy?
    assert_equal "legacy_bypass", legacy.reason
    assert_empty legacy.candidates
    refute explicit.selected?
    assert_equal "no_eligible_provider_route", explicit.reason
    assert_equal [ "manual_block" ], explicit.exclusions.map(&:reason)
  end

  private

  def health_store(root_suffix: nil)
    Hive::ProviderHealth::Store.new(
      root: File.join(@root, [ "health", root_suffix ].compact.join("-")),
      clock: -> { @clock || NOW },
      attempt_reader: ->(attempt_id) { @attempts[attempt_id] }
    )
  end

  def decide(policy:, decision_id:, store: @health, capacity: capacity())
    health = policy.routes.to_h do |route|
      [
        route.id,
        store.evaluate_route(account_id: route.account, model_id: route.model, now: NOW)
      ]
    end
    request = Hive::ProviderRouting::Request.new(
      policy: policy,
      task_generation: "generation-1",
      health: health,
      capacity: capacity
    )
    Hive::ProviderRouting::Router.new.call(
      request: request,
      decision_id: decision_id,
      decided_at: DECIDED_AT
    )
  end

  def policy(routes: self.routes, pin: nil, accounts: %w[account-a account-b])
    Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: routes,
      requirements: Hive::ProviderRouting::Requirements.empty,
      pin: pin,
      account_policy: accounts.to_h do |account_id|
        route = self.routes.find { |candidate| candidate.account == account_id }
        [
          account_id,
          {
            "adapter" => route.adapter,
            "launch_binding" => route.launch_binding,
            "models" => [ route.model ],
            "max_concurrent" => 1,
            "cooldown_sec" => Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
          }
        ]
      end
    )
  end

  def pinned_policy_for(reason)
    scope = model_scope("account-a", "model-a")
    case reason
    when "circuit_cooldown"
      open_scope(scope, failure_class: "model_capacity", attempt_id: "attempt-cooldown")
    when "manual_block"
      @health.block(
        scope: scope, expected_generation: 0,
        actor: "uid:1000", reason: "strict pin maintenance"
      )
    when "half_open_probe_owned"
      open_scope(
        scope, failure_class: "model_capacity", attempt_id: "attempt-half-open"
      )
      @clock = NOW + 301
      evaluation = @health.evaluate_route(
        account_id: "account-a", model_id: "model-a", now: @clock
      )
      intent = Hive::ProviderHealth::ProbeIntent.new(
        intent_id: "intent-half-open",
        attempt_id: "attempt-probe",
        task_generation: "generation-1",
        ownership_fence: "fence-1",
        requirements: evaluation.probe_requirements
      )
      @health.with_probe_intent(intent: intent) do |bindings|
        @attempts[intent.attempt_id] = Hive::ProviderHealth::AttemptBinding.new(
          attempt_id: intent.attempt_id,
          task_generation: intent.task_generation,
          ownership_fence: intent.ownership_fence,
          route: route_identity("account-a"),
          probe_bindings: bindings
        )
      end
    end
    requirements = if reason == "requirements_incompatible"
      Hive::ProviderRouting::Requirements.new(tools: %w[browser])
    else
      Hive::ProviderRouting::Requirements.empty
    end
    Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: routes,
      requirements: requirements,
      pin: Hive::ProviderRouting::Pin.new(account: "account-a", model: "model-a"),
      account_policy: policy.account_policy
    )
  ensure
    @clock = NOW
  end

  def routes
    @routes ||= [
      route("account-a", "model-a", "codex", "binding-a", 0),
      route("account-b", "model-b", "claude", "binding-b", 1)
    ].freeze
  end

  def route(account, model, adapter, binding, order)
    Hive::ProviderRouting::Route.new(
      id: "#{account}/#{model}",
      account: account,
      adapter: adapter,
      launch_binding: binding,
      model: model,
      effort: "high",
      order: order,
      capabilities: {
        "context" => "large",
        "quality" => "high",
        "tools" => %w[shell],
        "permissions" => %w[read]
      }
    )
  end

  def capacity(overrides = {})
    { "account-a" => 0, "account-b" => 0 }.merge(overrides).to_h do |account, observed|
      [ account, { "observed" => observed, "max" => 1 } ]
    end
  end

  def open_scope(scope, failure_class:, attempt_id:)
    route = route_identity(scope.account_id)
    attempt = Hive::ProviderHealth::AttemptBinding.new(
      attempt_id: attempt_id,
      task_generation: "generation-1",
      ownership_fence: "fence-1",
      route: route
    )
    @attempts[attempt_id] = attempt
    reference = {
      "path" => "logs/#{attempt_id}.frames",
      "size" => 0,
      "sha256" => Digest::SHA256.hexdigest("")
    }
    evidence = Hive::ProviderHealth::Evidence.new(
      scope: scope,
      failure_class: failure_class,
      provenance: "provider_diagnostic",
      route: route,
      reset_hint_seconds: 300,
      source_reference: reference,
      attempt_id: attempt_id
    )
    receipt = {
      "attempt_id" => attempt_id,
      "receipt_version" => 1,
      "terminal_lease_version" => 2
    }
    result = @health.apply_evidence(
      evidence: evidence,
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )
    assert result.accepted?
    [ evidence, attempt, receipt ]
  end

  def route_identity(account_id)
    configured = routes.find { |candidate| candidate.account == account_id }
    Hive::ProviderHealth::RouteIdentity.new(
      route_id: configured.id,
      account_id: configured.account,
      adapter: configured.adapter,
      launch_binding_id: configured.launch_binding,
      model_id: configured.model
    )
  end

  def provider_scope(account_id)
    Hive::ProviderHealth::Scope.provider_account(account_id: account_id)
  end

  def model_scope(account_id, model_id)
    Hive::ProviderHealth::Scope.model(account_id: account_id, model_id: model_id)
  end

  def all_scopes
    routes.flat_map do |route|
      [ provider_scope(route.account), model_scope(route.account, route.model) ]
    end
  end
end
