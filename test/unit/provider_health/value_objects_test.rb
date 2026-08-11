require_relative "../../test_helper"
require "hive/provider_health/reconciler"

class ProviderHealthValueObjectsTest < Minitest::Test
  def test_scope_and_route_identity_reject_invalid_composition
    assert_raises(Hive::ProviderHealth::InvalidScope) do
      Hive::ProviderHealth::Scope.new(kind: "account", account_id: "account-a")
    end
    assert_raises(Hive::ProviderHealth::InvalidScope) do
      Hive::ProviderHealth::Scope.new(
        kind: "provider_account", account_id: "account-a", model_id: "model-a"
      )
    end
    assert_raises(Hive::ProviderHealth::InvalidScope) do
      Hive::ProviderHealth::Scope.new(kind: "model", account_id: "account-a")
    end

    assert_equal "account-a/model-a", route.to_h.fetch("route_id")
  end

  def test_probe_values_require_typed_nonduplicated_scope_bindings
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      probe_binding(scope: Object.new)
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      probe_binding(observed_generation: 1, claim_generation: 4)
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      Hive::ProviderHealth::ProbeRequirement.new(
        scope: Object.new, journal_epoch: 0, observed_generation: 0
      )
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      probe_intent([])
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      probe_intent([ requirement, requirement ])
    end

    assert_equal [ requirement.to_h ], probe_intent([ requirement ]).to_h.fetch("requirements")
  end

  def test_attempt_corruption_and_evaluation_values_validate_types
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      attempt_binding(route: Object.new)
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      attempt_binding(probe_bindings: [ Object.new ])
    end
    assert_equal route.to_h, attempt_binding.to_h.fetch("route")

    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      corruption_token(scope: Object.new)
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      corruption_token(corruption_fingerprint: "not-a-digest")
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      Hive::ProviderHealth::RouteEvaluation.new(
        status: "eligible", inspections: [], blockers: [],
        probe_requirements: [ Object.new ]
      )
    end
  end

  def test_parsing_helpers_fail_closed_and_canonicalize_safe_values
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      Hive::ProviderHealth.identifier(7, "fixture")
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      Hive::ProviderHealth.nonnegative_integer("not-an-integer", "fixture")
    end
    assert_raises(Hive::ProviderHealth::InvalidScope) do
      Hive::ProviderHealth.scope_from_h("kind" => "other", "model" => nil,
                                       "provider_account_id" => "account-a")
    end
    assert_raises(Hive::ProviderHealth::InvalidScope) do
      Hive::ProviderHealth.scope_from_h("kind" => "provider_account")
    end

    incomplete = provider_scope.to_h.dup
    incomplete.define_singleton_method(:fetch) do |key, *defaults|
      raise KeyError, key if key == "kind"

      super(key, *defaults)
    end
    assert_raises(Hive::ProviderHealth::InvalidScope) do
      Hive::ProviderHealth.scope_from_h(incomplete)
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      Hive::ProviderHealth.parse_time("not-a-time", "fixture")
    end

    at = Time.utc(2026, 8, 11, 2)
    assert_equal %({"at":"#{at.iso8601(6)}","kind":"probe"}),
                 Hive::ProviderHealth.canonical_json(at: at, kind: :probe)
  end

  def test_default_factory_and_reconciler_use_the_typed_store
    Dir.mktmpdir("provider-health-values") do |root|
      store = Hive::ProviderHealth.open(root: File.join(root, "health"))

      assert_instance_of Hive::ProviderHealth::Store, store
      assert_equal [], Hive::ProviderHealth::Reconciler.new(store: store).call
      assert_raises(Hive::ProviderHealth::InvalidMutation) do
        Hive::ProviderHealth::Reconciler.new(store: Object.new)
      end
    end
  end

  private

  def provider_scope
    @provider_scope ||= Hive::ProviderHealth::Scope.provider_account(account_id: "account-a")
  end

  def route
    @route ||= Hive::ProviderHealth::RouteIdentity.new(
      route_id: "account-a/model-a", account_id: "account-a", adapter: "codex",
      launch_binding_id: "default", model_id: "model-a"
    )
  end

  def requirement
    @requirement ||= Hive::ProviderHealth::ProbeRequirement.new(
      scope: provider_scope, journal_epoch: 0, observed_generation: 1
    )
  end

  def probe_binding(scope: provider_scope, observed_generation: 1, claim_generation: 2)
    Hive::ProviderHealth::ProbeBinding.new(
      scope: scope, journal_epoch: 0, observed_generation: observed_generation,
      claim_generation: claim_generation, attempt_id: "attempt-1",
      task_generation: "generation-1", ownership_fence: "fence-1"
    )
  end

  def probe_intent(requirements)
    Hive::ProviderHealth::ProbeIntent.new(
      intent_id: "intent-1", attempt_id: "attempt-1",
      task_generation: "generation-1", ownership_fence: "fence-1",
      requirements: requirements
    )
  end

  def attempt_binding(route: self.route, probe_bindings: [ probe_binding ])
    Hive::ProviderHealth::AttemptBinding.new(
      attempt_id: "attempt-1", task_generation: "generation-1",
      ownership_fence: "fence-1", route: route, probe_bindings: probe_bindings
    )
  end

  def corruption_token(scope: provider_scope, corruption_fingerprint: "a" * 64)
    Hive::ProviderHealth::CorruptionToken.new(
      scope: scope, journal_epoch: 0,
      corruption_fingerprint: corruption_fingerprint,
      last_verified_generation: 0
    )
  end
end
