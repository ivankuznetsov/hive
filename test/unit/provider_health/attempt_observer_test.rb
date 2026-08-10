require "test_helper"
require "hive/provider_health/attempt_observer"

class ProviderHealthAttemptObserverTest < Minitest::Test
  FakeRecord = Struct.new(
    :state, :data, :receipt, :attempt_id, :task_generation,
    :ownership_generation, :lease_version,
    keyword_init: true
  ) do
    def [](key) = data[key]
  end

  def setup
    @tmp = Dir.mktmpdir("provider-health-observer")
    @attempts = {}
    @store = Hive::ProviderHealth::Store.new(
      root: File.join(@tmp, "health"),
      clock: -> { Time.utc(2026, 8, 10, 12) },
      attempt_reader: ->(id) { @attempts[id] }
    )
    @observer = Hive::ProviderHealth::AttemptObserver.new(store: @store)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_failed_terminal_evidence_opens_only_its_exact_scope_once
    record = terminal_record(evidence_scope: model_scope)
    bind(record)

    assert_equal :acknowledged, @observer.observe(record)
    assert_equal :acknowledged, @observer.observe(record)

    assert_equal "open", @store.inspect_scope(model_scope).circuit.automatic_state
    assert_equal 1, @store.inspect_scope(model_scope).generation
    assert_equal "closed", @store.inspect_scope(provider_scope).circuit.automatic_state
    assert_equal 0, @store.inspect_scope(provider_scope).generation
  end

  def test_task_local_terminal_and_legacy_record_acknowledge_without_mutation
    explicit = terminal_record(evidence_scope: nil)
    bind(explicit)
    legacy = explicit.dup
    legacy.data = { "routing" => { "mode" => "legacy" } }

    assert_equal :acknowledged, @observer.observe(explicit)
    assert_equal :not_applicable, @observer.observe(legacy)
    assert_equal 0, @store.inspect_scope(provider_scope).generation
    assert_equal 0, @store.inspect_scope(model_scope).generation
  end

  def test_operator_generation_change_fences_later_terminal_evidence
    record = terminal_record(evidence_scope: provider_scope)
    bind(record)
    @store.block(
      scope: provider_scope,
      expected_generation: 0,
      actor: "uid:1000",
      reason: "operator maintenance"
    )

    assert_equal :acknowledged, @observer.observe(record)

    inspection = @store.inspect_scope(provider_scope)
    assert_equal 1, inspection.generation
    assert inspection.circuit.blocked?
    assert_equal "closed", inspection.circuit.automatic_state
  end

  private

  def bind(record)
    @attempts[record.attempt_id] = {
      "attempt_id" => record.attempt_id,
      "task_generation" => record.task_generation,
      "ownership_fence" => record.ownership_generation,
      "state" => record.state
    }
  end

  def terminal_record(evidence_scope:)
    evidence = if evidence_scope
      failure_class = evidence_scope.model? ? "model_capacity" : "provider_outage"
      Hive::ProviderHealth::Evidence.new(
        scope: evidence_scope,
        failure_class: failure_class,
        provenance: "codex_jsonl_transport",
        route: route,
        reset_hint_seconds: 30,
        source_reference: reference,
        attempt_id: "attempt-1"
      ).to_h
    end
    FakeRecord.new(
      state: "terminal",
      data: { "routing" => routing },
      receipt: {
        "attempt_id" => "attempt-1", "receipt_version" => 1,
        "terminal_lease_version" => 3, "outcome" => "failed",
        "provider_evidence" => evidence
      },
      attempt_id: "attempt-1",
      task_generation: "generation-1",
      ownership_generation: "generation-1",
      lease_version: 3
    )
  end

  def route
    @route ||= Hive::ProviderHealth::RouteIdentity.new(
      route_id: "account-a/model-a", account_id: "account-a",
      adapter: "codex", launch_binding_id: "default", model_id: "model-a"
    )
  end

  def provider_scope
    @provider_scope ||= Hive::ProviderHealth::Scope.provider_account(account_id: "account-a")
  end

  def model_scope
    @model_scope ||= Hive::ProviderHealth::Scope.model(
      account_id: "account-a", model_id: "model-a"
    )
  end

  def routing
    {
      "mode" => "explicit", "policy_digest" => "a" * 64,
      "decision" => {
        "decision_id" => "decision-1", "policy_digest" => "a" * 64,
        "decided_at" => Time.utc(2026, 8, 10, 12).iso8601(6), "exclusions" => []
      },
      "route" => {
        "route_id" => route.route_id, "provider_account_id" => route.account_id,
        "adapter" => route.adapter, "launch_binding_id" => route.launch_binding_id,
        "model" => route.model_id, "effort" => "high"
      },
      "circuit_generations" => [
        { "scope" => provider_scope.to_h, "journal_epoch" => 0, "observed_generation" => 0 },
        { "scope" => model_scope.to_h, "journal_epoch" => 0, "observed_generation" => 0 }
      ],
      "probe_bindings" => []
    }
  end

  def reference
    { "path" => "logs/attempt.frames", "size" => 1, "sha256" => "b" * 64 }
  end
end
