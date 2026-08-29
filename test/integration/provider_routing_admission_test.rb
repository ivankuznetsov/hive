require_relative "../test_helper"
require "hive/attempts/dispatcher"
require "hive/provider_health/store"
require "hive/provider_routing"

class ProviderRoutingAdmissionTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12)
  CLAIM_CAPABILITY = "c" * 64
  FakeTask = Struct.new(
    :id, :slug, :state_file, :stage_index, :stage_name, :project_root,
    :worktree_path, :workflow, keyword_init: true
  )

  class Launcher
    attr_reader :launched

    def initialize
      @launched = []
    end

    def preflight! = true

    def launch(record, claim_capability:)
      @launched << [ record, claim_capability ]
      { "claimed" => true }
    end
  end

  class RacingHealth
    def initialize(store, scope)
      @store = store
      @scope = scope
      @raced = false
    end

    def reconcile! = @store.reconcile!

    def evaluate_routes(**attributes)
      @store.evaluate_routes(**attributes)
    end

    def with_route_admission(**attributes, &block)
      unless @raced
        @raced = true
        @store.block(
          scope: @scope,
          expected_generation: 0,
          actor: "uid:1000",
          reason: "race before admission"
        )
      end
      @store.with_route_admission(**attributes, &block)
    end
  end

  def setup
    @root = Dir.mktmpdir("provider-routing-admission")
    @store = Hive::Attempts::Repository.new(
      root: File.join(@root, "attempts"), migrate: true
    )
    @launcher = Launcher.new
    @ids = (1..20).map { |number| "attempt-#{number}" }.each
    @decision_ids = (1..20).map { |number| "decision-#{number}" }.each
    @attempt_bindings = {}
    @health = Hive::ProviderHealth::Store.new(
      root: File.join(@root, "health"),
      clock: -> { NOW },
      attempt_reader: method(:read_health_attempt)
    )
    @dispatcher = build_dispatcher
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_legacy_admission_never_constructs_or_reads_provider_health
    dispatcher = build_dispatcher(
      health_store: nil,
      health_store_factory: -> { raise "legacy path touched health" }
    )

    result = dispatcher.dispatch(
      **dispatch_attributes(task("legacy", 1)),
      routing_policy: Hive::ProviderRouting::Policy.legacy(stage: "execute")
    )

    assert_equal :accepted, result.status
    assert_equal({ "mode" => "legacy" }, result.attempt["routing"])
    assert_equal "codex", result.attempt["provider"]
  end

  def test_selected_route_and_closed_generation_vector_are_committed_with_attempt
    result = dispatch(task("selected", 2), policy: policy)

    assert_equal :accepted, result.status
    assert result.decision.selected?
    assert_equal "account-a/model-a", result.decision.route.id
    assert_equal "codex", result.attempt["provider"]
    assert_equal "account-a", result.attempt["routing"].dig("route", "provider_account_id")
    assert_equal "binding-a", result.attempt["routing"].dig("route", "launch_binding_id")
    assert_equal "subscription", result.attempt["routing"].dig("route", "billing_route")
    assert_equal "agent_profile_contract",
                 result.attempt["routing"].dig("route", "billing_evidence_source")
    assert_equal policy.digest, result.attempt["routing"].fetch("policy_digest")
    assert_equal 2, result.attempt["routing"].fetch("circuit_generations").length
    assert_empty result.attempt["routing"].fetch("probe_bindings")
    assert_equal result.decision.to_h, @store.routing_decision(
      task_generation: result.attempt.task_generation,
      subject: result.attempt.subject
    )
  end

  def test_admission_requests_one_health_batch_for_the_complete_route_pool
    calls = []
    original_batch = @health.method(:evaluate_routes)
    @health.define_singleton_method(:evaluate_routes) do |**attributes|
      calls << attributes.fetch(:routes)
      original_batch.call(**attributes)
    end
    @health.define_singleton_method(:evaluate_route) do |**|
      raise "dispatcher must use the batch health snapshot"
    end

    result = dispatch(task("batch-health", 16), policy: policy)

    assert_equal :accepted, result.status
    assert_equal 1, calls.length
    assert_equal(
      [
        { account_id: "account-a", model_id: "model-a" },
        { account_id: "account-b", model_id: "model-b" }
      ],
      calls.first
    )
  end

  def test_manual_block_falls_back_in_configured_order
    @health.block(
      scope: provider_scope("account-a"),
      expected_generation: 0,
      actor: "uid:1000",
      reason: "maintenance"
    )

    result = dispatch(task("fallback", 3), policy: policy)

    assert_equal :accepted, result.status
    assert_equal "account-b/model-b", result.decision.route.id
    assert_equal "claude", result.attempt["provider"]
    assert_equal [ "manual_block" ], result.decision.exclusions.map(&:reason)
  end

  def test_provider_capacity_is_ledger_derived_and_all_saturation_creates_nothing
    first = dispatch(task("capacity-a", 4), policy: policy)
    second = dispatch(task("capacity-b", 5), policy: policy)
    before = @store.scan.records.map(&:attempt_id).sort

    saturated = dispatch(task("capacity-c", 6), policy: policy)

    assert_equal "account-a", first.attempt["routing"].dig("route", "provider_account_id")
    assert_equal "account-b", second.attempt["routing"].dig("route", "provider_account_id")
    assert_equal :deferred, saturated.status
    assert_equal "capacity_saturated", saturated.reason
    assert saturated.decision.capacity_saturated?
    assert_equal "scheduler", saturated.decision.next_action_owner
    assert_nil saturated.attempt
    assert_equal before, @store.scan.records.map(&:attempt_id).sort
    assert_equal 2, @launcher.launched.length
  end

  def test_unambiguous_legacy_default_attempt_counts_against_explicit_account_only
    legacy_task = task("legacy-default", 11)
    legacy = @dispatcher.dispatch(
      **dispatch_attributes(legacy_task),
      routing_policy: Hive::ProviderRouting::Policy.legacy(stage: "execute")
    )

    explicit = dispatch(task("after-legacy", 12), policy: legacy_aware_policy)

    assert_equal :accepted, legacy.status
    assert_equal "account-b/model-b", explicit.decision.route.id
    assert_equal [ "provider_concurrency_saturated" ], explicit.decision.exclusions.map(&:reason)
  end

  def test_first_no_route_freezes_policy_before_config_changes
    %w[account-a account-b].each do |account_id|
      @health.block(
        scope: provider_scope(account_id),
        expected_generation: 0,
        actor: "uid:1000",
        reason: "maintenance"
      )
    end
    routed_task = task("frozen", 7)
    generation = "generation-frozen"
    first = dispatch(routed_task, policy: policy, generation: generation)
    changed = single_route_policy("account-b")
    replay = dispatch(routed_task, policy: changed, generation: generation)

    assert_equal :no_route, first.status
    assert_equal "no_eligible_provider_route", first.reason
    assert_nil first.attempt
    assert_equal first.decision.policy_digest, replay.decision.policy_digest
    assert_equal policy.digest, replay.decision.policy_digest
    assert_equal %w[account-a/model-a account-b/model-b],
                 replay.decision.candidates.map { |candidate| candidate.route.id }
    assert_empty @launcher.launched
  end

  def test_preselection_reconciliation_failure_is_a_typed_no_route_decision
    failing_health = Object.new
    failing_health.define_singleton_method(:reconcile!) do
      raise Hive::ProviderHealth::Unavailable, "health_state_unavailable"
    end
    failing_health.define_singleton_method(:evaluate_routes) { |**| raise "must not evaluate" }
    dispatcher = build_dispatcher(health_store: failing_health)

    result = dispatcher.dispatch(
      **dispatch_attributes(task("health-unavailable", 13)),
      routing_policy: policy
    )

    assert_equal :no_route, result.status
    assert_equal "health_state_unavailable", result.reason
    assert_equal "operator", result.decision.next_action_owner
    assert_equal [ "health_state_unavailable" ], result.decision.exclusions.map(&:reason).uniq
    assert_nil result.attempt
  end

  def test_health_store_construction_failure_is_a_durable_typed_no_route_decision
    factory_calls = 0
    errors = [ Hive::ProviderHealth::Unavailable, Hive::ManagedDirectory::UnsafeError ]

    results = errors.each_with_index.map do |error_class, index|
      dispatcher = build_dispatcher(
        health_store: nil,
        health_store_factory: lambda do
          factory_calls += 1
          raise error_class, "unsafe health root"
        end
      )
      dispatcher.dispatch(
        **dispatch_attributes(task("health-construction-unavailable-#{index}", 14 + index)),
        routing_policy: policy
      )
    end

    assert_equal 2, factory_calls
    results.each do |result|
      assert_equal :no_route, result.status
      assert_equal "health_state_unavailable", result.reason
      assert_equal "operator", result.decision.next_action_owner
      assert_equal [ "health_state_unavailable" ], result.decision.exclusions.map(&:reason).uniq
      assert_nil result.attempt
    end
    assert_equal results.map { |result| result.decision.to_h }.sort_by { |decision| decision["decision_id"] },
                 @store.routing_decisions.map { |entry| entry.fetch("decision") }
                   .sort_by { |decision| decision["decision_id"] }
  end

  def test_one_admission_claims_both_half_open_scopes_and_concurrent_work_uses_b
    open_scope(provider_scope("account-a"), failure_class: "account_quota")
    open_scope(model_scope("account-a", "model-a"), failure_class: "model_capacity")

    probe = dispatch(task("probe", 8), policy: policy)
    fallback = dispatch(task("probe-follower", 9), policy: policy)

    assert_equal "account-a/model-a", probe.decision.route.id
    assert_equal 2, probe.attempt["routing"].fetch("probe_bindings").length
    claim_generations = probe.attempt["routing"].fetch("probe_bindings").map do |binding|
      binding.fetch("claim_generation")
    end
    assert_equal [ 2, 2 ], claim_generations
    assert_equal "account-b/model-b", fallback.decision.route.id
    assert_equal [ "half_open_probe_owned" ], fallback.decision.exclusions.map(&:reason).uniq
    assert @health.inspect_scope(provider_scope("account-a")).circuit.probe_owned?
    assert @health.inspect_scope(model_scope("account-a", "model-a")).circuit.probe_owned?
  end

  def test_generation_change_between_selection_and_commit_is_re_evaluated
    racing = RacingHealth.new(@health, provider_scope("account-a"))
    dispatcher = build_dispatcher(health_store: racing)

    result = dispatcher.dispatch(
      **dispatch_attributes(task("generation-race", 10)),
      routing_policy: policy
    )

    assert_equal :accepted, result.status
    assert_equal "account-b/model-b", result.decision.route.id
    assert_equal 1, @store.scan.records.length
    assert_equal 1, @launcher.launched.length
  end

  private

  def build_dispatcher(health_store: @health, health_store_factory: nil)
    Hive::Attempts::Dispatcher.new(
      store: @store,
      launcher: @launcher,
      limits: { max_global: 20, max_per_project: 20, max_daily: 50 },
      clock: -> { NOW },
      id_generator: -> { @ids.next },
      decision_id_generator: -> { @decision_ids.next },
      capability_generator: -> { CLAIM_CAPABILITY },
      health_store: health_store,
      health_store_factory: health_store_factory
    )
  end

  def dispatch(routed_task, policy:, generation: nil)
    @dispatcher.dispatch(
      **dispatch_attributes(routed_task),
      generation: generation,
      routing_policy: policy
    )
  end

  def dispatch_attributes(routed_task)
    {
      task: routed_task,
      project: "demo",
      intended_stage: "4-execute",
      argv: [ "hive", "run", routed_task.slug ],
      request_id: "request-#{routed_task.slug}",
      provider: "codex",
      now: NOW
    }
  end

  def task(slug, id)
    state_file = File.join(@root, "#{slug}.md")
    File.write(state_file, "#{slug}\n<!-- WAITING -->\n")
    FakeTask.new(
      id: id,
      slug: slug,
      state_file: state_file,
      stage_index: 4,
      stage_name: "execute"
    )
  end

  def policy
    @policy ||= Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: [ route("account-a", "model-a", "codex", "binding-a", 0),
                route("account-b", "model-b", "claude", "binding-b", 1) ],
      requirements: Hive::ProviderRouting::Requirements.empty,
      pin: nil,
      account_policy: {
        "account-a" => account("codex", "binding-a", "model-a"),
        "account-b" => account("claude", "binding-b", "model-b")
      }
    )
  end

  def single_route_policy(account_id)
    candidate = policy.routes.find { |route| route.account == account_id }
    Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: [ candidate.with(order: 0) ],
      requirements: Hive::ProviderRouting::Requirements.empty,
      pin: nil,
      account_policy: { account_id => policy.account_policy.fetch(account_id) }
    )
  end

  def legacy_aware_policy
    Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: [ route("account-a", "model-a", "codex", "default", 0),
                route("account-b", "model-b", "claude", "binding-b", 1) ],
      requirements: Hive::ProviderRouting::Requirements.empty,
      pin: nil,
      account_policy: {
        "account-a" => account("codex", "default", "model-a"),
        "account-b" => account("claude", "binding-b", "model-b")
      }
    )
  end

  def route(account_id, model, adapter, binding, order)
    Hive::ProviderRouting::Route.new(
      id: "#{account_id}/#{model}",
      account: account_id,
      adapter: adapter,
      launch_binding: binding,
      model: model,
      effort: "high",
      order: order,
      billing_route: "subscription",
      billing_evidence_source: "agent_profile_contract",
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

  def provider_scope(account_id)
    Hive::ProviderHealth::Scope.provider_account(account_id: account_id)
  end

  def model_scope(account_id, model)
    Hive::ProviderHealth::Scope.model(account_id: account_id, model_id: model)
  end

  def open_scope(scope, failure_class:)
    route = Hive::ProviderHealth::RouteIdentity.new(
      route_id: "account-a/model-a",
      account_id: "account-a",
      adapter: "codex",
      launch_binding_id: "binding-a",
      model_id: "model-a"
    )
    attempt = Hive::ProviderHealth::AttemptBinding.new(
      attempt_id: "evidence-attempt-#{scope.kind}",
      task_generation: "evidence-generation",
      ownership_fence: "evidence-fence",
      route: route
    )
    @attempt_bindings[attempt.attempt_id] = attempt
    evidence = Hive::ProviderHealth::Evidence.new(
      scope: scope,
      failure_class: failure_class,
      provenance: "provider_diagnostic",
      route: route,
      reset_hint_seconds: 0,
      source_reference: {
        "path" => "logs/evidence.frames", "size" => 0, "sha256" => "0" * 64
      },
      attempt_id: attempt.attempt_id
    )
    @health.apply_evidence(
      evidence: evidence,
      attempt: attempt,
      terminal_receipt: {
        "attempt_id" => attempt.attempt_id,
        "receipt_version" => 1,
        "terminal_lease_version" => 2
      },
      expected_generation: 0
    )
  end

  def read_health_attempt(attempt_id)
    return @attempt_bindings[attempt_id] if @attempt_bindings.key?(attempt_id)

    record = @store.fetch_hot(attempt_id)
    return nil unless record

    {
      "attempt_id" => record.attempt_id,
      "task_generation" => record.task_generation,
      "ownership_fence" => record["ownership_generation"],
      "state" => record.state,
      "probe_bindings" => record["routing"].fetch("probe_bindings", [])
    }
  end
end
