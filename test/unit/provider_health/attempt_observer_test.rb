require "test_helper"
require "hive/attempts/repository"
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
    setup_repositories
  end

  def setup_repositories
    @attempt_repository = Hive::Attempts::Repository.new(
      root: File.join(@tmp, "attempts"), migrate: true
    )
    @attempt_repository.create_launching(
      attempt_id: "attempt-1", request_id: "request-1",
      predecessor_attempt_id: nil, task_id: "task-1", project: "demo",
      task_slug: "task-1", intended_stage: "4-execute",
      task_generation: "generation-1", ownership_generation: "generation-1",
      task_input_epoch: 1, progress_token: "source-1", provider: "codex",
      worker_argv: %w[hive run task-1],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: "a" * 40, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: Time.utc(2026, 8, 10, 12)
    )
    @store = Hive::ProviderHealth::Repository.new(
      database: @attempt_repository.database,
      clock: -> { Time.utc(2026, 8, 10, 12) }
    )
    @observer = Hive::ProviderHealth::AttemptObserver.new(store: @store)
  end

  def teardown
    @attempt_repository.database.disconnect
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

  def test_rejects_an_untyped_store_and_ignores_nonfinal_records
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      Hive::ProviderHealth::AttemptObserver.new(store: Object.new)
    end
    assert_equal :not_applicable, @observer.observe(nil)

    running = terminal_record(evidence_scope: model_scope)
    running.state = "running"
    assert_equal :not_applicable, @observer.observe(running)
  end

  def test_probe_success_is_completed_before_matching_evidence_is_applied
    binding = claim_probe(model_scope)
    record = terminal_record(evidence_scope: model_scope)
    record.receipt["outcome"] = "succeeded"
    record.data["routing"]["probe_bindings"] = [ binding.to_h ]
    bind(record)

    assert_equal :acknowledged, @observer.observe(record)
    inspection = @store.inspect_scope(model_scope)
    assert_equal "open", inspection.circuit.automatic_state
    assert_equal 4, inspection.generation
  end

  def test_lost_and_cancelled_probe_attempts_reopen_the_claim
    %w[lost cancelled].each do |outcome|
      reset_store
      binding = claim_probe(provider_scope)
      record = terminal_record(evidence_scope: nil)
      record.data["routing"]["probe_bindings"] = [ binding.to_h ]
      if outcome == "lost"
        record.state = "lost"
        record.receipt = nil
      else
        record.receipt["outcome"] = "cancelled"
      end
      bind(record)

      assert_equal :acknowledged, @observer.observe(record)
      assert_equal "open", @store.inspect_scope(provider_scope).circuit.automatic_state
      assert_equal 3, @store.inspect_scope(provider_scope).generation
    end
  end

  def test_probe_completion_fenced_by_operator_change_is_acknowledged_without_evidence
    binding = claim_probe(model_scope)
    record = terminal_record(evidence_scope: model_scope)
    record.data["routing"]["probe_bindings"] = [ binding.to_h ]
    bind(record)
    @store.block(
      scope: model_scope, expected_generation: binding.claim_generation,
      actor: "uid:1000", reason: "operator maintenance"
    )

    assert_equal :acknowledged, @observer.observe(record)
    assert_equal binding.claim_generation + 1, @store.inspect_scope(model_scope).generation
  end

  def test_evidence_without_an_enclosing_generation_is_rejected
    record = terminal_record(evidence_scope: model_scope)
    record.data["routing"]["circuit_generations"] = []
    bind(record)

    assert_raises(Hive::ProviderHealth::InvalidMutation) { @observer.observe(record) }
  end

  private

  def reset_store
    @attempt_repository.database.disconnect
    FileUtils.remove_entry(@tmp)
    FileUtils.mkdir_p(@tmp)
    setup_repositories
  end

  def claim_probe(scope)
    seed = terminal_record(evidence_scope: scope)
    bind(seed)
    signal = Hive::ProviderHealth::Evidence.new(
      scope: scope,
      failure_class: scope.model? ? "model_capacity" : "provider_outage",
      provenance: "codex_jsonl_transport", route: route,
      reset_hint_seconds: 0, source_reference: reference,
      attempt_id: seed.attempt_id
    )
    @store.apply_evidence(
      evidence: signal, attempt: observer_attempt,
      terminal_receipt: seed.receipt.slice(
        "attempt_id", "receipt_version", "terminal_lease_version"
      ),
      expected_generation: 0
    )
    evaluation = @store.evaluate_route(
      account_id: route.account_id, model_id: route.model_id,
      now: Time.utc(2026, 8, 10, 12)
    )
    requirement = evaluation.probe_requirements.find { |candidate| candidate.scope == scope }
    bindings = @store.database.transaction do |db|
      @store.claim_probe_bindings_in(
        db, requirements: [ requirement ], attempt_id: "attempt-1",
        task_generation: "generation-1", ownership_fence: "generation-1",
        now: Time.utc(2026, 8, 10, 12)
      )
    end
    bindings.fetch(0)
  end

  def observer_attempt(probe_bindings: [])
    Hive::ProviderHealth::AttemptBinding.new(
      attempt_id: "attempt-1", task_generation: "generation-1",
      ownership_fence: "generation-1", route: route,
      probe_bindings: probe_bindings
    )
  end

  def bind(record)
    outcome = record.state == "terminal" ? record.receipt.fetch("outcome") : nil
    @attempt_repository.database.transaction do |db|
      db[:attempts].where(attempt_id: record.attempt_id).update(
        state: record.state, outcome: outcome,
        ended_at: Time.utc(2026, 8, 10, 12).iso8601(6)
      )
      db[:capacity_reservations].where(attempt_id: record.attempt_id).update(
        state: "released", released_at: Time.utc(2026, 8, 10, 12).iso8601(6)
      )
    end
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
