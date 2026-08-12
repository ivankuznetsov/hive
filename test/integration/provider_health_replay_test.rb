require_relative "../test_helper"
require "hive/provider_health/store"

class ProviderHealthReplayTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("provider-health-replay")
    @root = File.join(@tmp, "health")
    @clock = Time.utc(2026, 8, 10, 12)
    @attempts = {}
    @store = store
    @attempts[attempt.attempt_id] = attempt
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_read_only_inspection_replays_torn_tail_without_writing_and_mutation_repairs_it
    open_scope(provider_scope, evidence(provider_scope))
    path = journal_file(provider_scope)
    valid = File.binread(path)
    File.binwrite(path, valid + %({"message":"secret-canary"))

    available_tail = store.inspect_scope(provider_scope)
    assert available_tail.available?
    assert_equal 1, available_tail.generation
    assert_includes File.binread(path), "secret-canary"

    repaired = store.block(
      scope: provider_scope, expected_generation: 1,
      actor: "uid:1000", reason: "repair torn suffix while mutating"
    )
    assert_equal 2, repaired.generation
    refute_includes File.binread(path), "secret-canary"
    assert File.binread(path).end_with?("\n")

    File.binwrite(path, "not-json\n#{valid}")
    unavailable = store.inspect_scope(provider_scope)
    assert unavailable.unavailable?
    assert_equal "health_state_unavailable", unavailable.unavailable_reason
    assert_match(/\A[0-9a-f]{64}\z/, unavailable.corruption_token.corruption_fingerprint)
    refute_includes unavailable.unavailable_reason, "not-json"
  end

  def test_empty_or_truncated_genesis_is_unavailable_and_preserved
    path = journal_file(provider_scope)
    FileUtils.mkdir_p(File.dirname(path))

    [ "".b, %({"schema":"hive-provider-health-event") ].each do |corrupt|
      File.binwrite(path, corrupt)
      unavailable = store.inspect_scope(provider_scope)

      assert unavailable.unavailable?
      assert_equal "health_state_unavailable", unavailable.unavailable_reason
      assert_equal Hive::ProviderHealth.digest(corrupt),
                   unavailable.corruption_token.corruption_fingerprint
      assert_equal corrupt, File.binread(path)
      evaluation = store.evaluate_route(
        account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
      )
      assert_includes evaluation.blockers.map { |blocker| blocker.fetch("reason") },
                      "health_state_unavailable"
    end
  end

  def test_generation_correct_probe_outcome_without_owner_is_corruption
    open_scope(provider_scope, evidence(provider_scope))
    path = journal_file(provider_scope)
    open = store.inspect_scope(provider_scope).circuit
    impossible = Hive::ProviderHealth::Event.new(
      event_id: "impossible-close",
      sequence: 2,
      scope: provider_scope,
      journal_epoch: open.journal_epoch,
      kind: "probe_closed",
      occurred_at: @clock,
      idempotency_key: Hive::ProviderHealth.digest("impossible-close"),
      expected_generation: open.generation,
      previous_generation: open.generation,
      resulting_generation: open.generation + 1,
      payload: { "receipt_identity" => Hive::ProviderHealth.digest("receipt") }
    )
    File.open(path, "ab") do |file|
      file.write("#{Hive::ProviderHealth.canonical_json(impossible.to_h)}\n")
    end

    unavailable = store.inspect_scope(provider_scope)

    assert unavailable.unavailable?
    assert_equal "health_state_unavailable", unavailable.unavailable_reason
    assert_equal 1, unavailable.corruption_token.last_verified_generation
  end

  def test_read_only_inspection_does_not_rebuild_projection
    open_scope(provider_scope, evidence(provider_scope))
    projection = projection_file(provider_scope)
    File.binwrite(projection, %({"message":"secret-canary"}\n))

    inspected = store.inspect_scope(provider_scope)

    assert inspected.available?
    assert_equal({ "message" => "secret-canary" }, JSON.parse(File.read(projection)))
  end

  def test_sequence_or_generation_gap_is_unavailable_without_parser_content
    open_scope(provider_scope, evidence(provider_scope))
    path = journal_file(provider_scope)
    event = JSON.parse(File.read(path))
    event["sequence"] = 2
    File.binwrite(path, "#{JSON.generate(event)}\n")

    unavailable = store.inspect_scope(provider_scope)

    assert unavailable.unavailable?
    assert_equal "health_state_unavailable", unavailable.unavailable_reason
    assert_equal 0, unavailable.corruption_token.last_verified_generation
  end

  def test_duplicate_identity_corruption_preserves_only_the_verified_prefix
    open_scope(provider_scope, evidence(provider_scope))
    @store.block(
      scope: provider_scope,
      expected_generation: 1,
      actor: "uid:1000",
      reason: "planned maintenance"
    )
    path = journal_file(provider_scope)
    events = File.readlines(path).map { |line| JSON.parse(line) }
    events.fetch(1)["idempotency_key"] = events.fetch(0).fetch("idempotency_key")
    File.binwrite(path, events.map { |event| "#{JSON.generate(event)}\n" }.join)

    unavailable = store.inspect_scope(provider_scope)

    assert unavailable.unavailable?
    assert_equal 1, unavailable.corruption_token.last_verified_generation

    repaired = store.reset(
      scope: provider_scope,
      corruption_token: unavailable.corruption_token,
      actor: "uid:1000",
      reason: "repair duplicate journal identity"
    )
    assert_equal 2, repaired.generation
    refute repaired.current.blocked?
  end

  def test_corruption_token_reset_quarantines_exact_bytes_preserves_block_and_fences_old_token
    unrelated_before = store.inspect_scope(model_scope).circuit.to_h
    blocked = @store.block(
      scope: provider_scope,
      expected_generation: 0,
      actor: "uid:1000",
      reason: "planned maintenance"
    )
    path = journal_file(provider_scope)
    corrupt = File.binread(path) + "interior-corruption\n"
    File.binwrite(path, corrupt)
    unavailable = store.inspect_scope(provider_scope)

    repaired = store.reset(
      scope: provider_scope,
      corruption_token: unavailable.corruption_token,
      actor: "uid:1000",
      reason: "repair verified journal corruption"
    )

    assert_equal blocked.generation + 1, repaired.generation
    assert_equal 1, repaired.current.journal_epoch
    assert repaired.current.blocked?
    assert_equal "closed", repaired.current.automatic_state
    quarantine = Dir.glob(File.join(@root, "quarantine", "**", "*.jsonl"))
    assert_equal 1, quarantine.length
    assert_equal corrupt, File.binread(quarantine.first)
    assert_equal quarantine.first.delete_prefix("#{@root}/"),
                 repaired.audit_receipt.artifact_reference.fetch("path")
    assert_equal unrelated_before, store.inspect_scope(model_scope).circuit.to_h
    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      store.reset(
        scope: provider_scope,
        corruption_token: unavailable.corruption_token,
        actor: "uid:1000",
        reason: "repeat stale repair"
      )
    end
  end

  def test_compaction_preserves_state_duplicate_evidence_and_later_mutation_after_restart
    signal = evidence(provider_scope)
    opened = open_scope(provider_scope, signal)
    blocked = @store.block(
      scope: provider_scope,
      expected_generation: opened.generation,
      actor: "uid:1000",
      reason: "preserve maintenance across compaction"
    )
    before = blocked.current.to_h
    replay = @store.send(
      :load_replay, provider_scope, recover_torn: true, publish_projection: false
    )

    compacted = @store.send(:compact_replay, replay)
    restarted = store
    after = restarted.inspect_scope(provider_scope)
    duplicate = restarted.apply_evidence(
      evidence: signal,
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )
    unblocked = restarted.unblock(
      scope: provider_scope,
      expected_generation: blocked.generation,
      actor: "uid:1000",
      reason: "continue normally after compaction"
    )

    assert_equal before, compacted.circuit.to_h
    assert_equal before, after.circuit.to_h
    assert duplicate.duplicate?
    assert_equal opened.event_id, duplicate.event_id
    assert_equal blocked.generation + 1, unblocked.generation
    refute unblocked.current.blocked?
    assert_equal 1, Dir.glob(File.join(@root, "history", "**", "*.jsonl")).size
  end

  def test_multi_scope_probe_claim_restart_and_success_are_exactly_once
    open_scope(provider_scope, evidence(provider_scope, reset_hint_seconds: 0))
    open_scope(model_scope, evidence(model_scope, failure_class: "model_capacity", reset_hint_seconds: 0))
    evaluation = @store.evaluate_route(
      account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
    )
    assert evaluation.eligible?
    assert_equal 2, evaluation.probe_requirements.length
    intent = probe_intent(evaluation.probe_requirements)
    admitted = nil
    @store.with_probe_intent(intent: intent) do |bindings|
      admitted = build_attempt(probe_bindings: bindings)
      @attempts[admitted.attempt_id] = admitted
    end

    excluded = store.evaluate_route(
      account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
    )
    assert_equal %w[half_open_probe_owned half_open_probe_owned],
                 excluded.blockers.map { |entry| entry.fetch("reason") }
    completed = store.complete_probe(
      attempt: admitted,
      terminal_receipt: receipt,
      outcome: "success"
    )
    duplicate = store.complete_probe(
      attempt: admitted,
      terminal_receipt: receipt,
      outcome: "success"
    )

    assert completed.all?(&:accepted?)
    assert duplicate.all?(&:duplicate?)
    assert_equal [ 3, 3 ], [ provider_scope, model_scope ].map { |scope| store.inspect_scope(scope).generation }
    assert store.evaluate_route(
      account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
    ).eligible?
  end

  def test_operator_block_rechecks_generation_after_reconciling_live_intent
    assert_operator_intent_race_fenced(:block)
  end

  def test_operator_reset_rechecks_generation_after_reconciling_live_intent
    assert_operator_intent_race_fenced(:reset)
  end

  def test_restart_finalizes_partial_multi_scope_claim_from_durable_attempt
    open_scope(provider_scope, evidence(provider_scope, reset_hint_seconds: 0))
    open_scope(model_scope, evidence(model_scope, failure_class: "model_capacity", reset_hint_seconds: 0))
    evaluation = @store.evaluate_route(
      account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
    )
    intent = probe_intent(evaluation.probe_requirements)
    crashing = store(
      fault_injector: lambda do |phase, context|
        raise "simulated crash" if phase == :claim_persisted && context.fetch(:index).zero?
      end
    )

    assert_raises(RuntimeError) do
      crashing.with_probe_intent(intent: intent) do |bindings|
        @attempts[intent.attempt_id] = build_attempt(probe_bindings: bindings)
      end
    end
    before = [ provider_scope, model_scope ].map { |scope| store.inspect_scope(scope).generation }
    assert_equal [ 2, 1 ], before

    results = store.reconcile!

    assert_equal 1, results.length
    assert_equal [ 2, 2 ], [ provider_scope, model_scope ].map { |scope| store.inspect_scope(scope).generation }
    assert_empty Dir.glob(File.join(@root, "intents", "*.json"))
  end

  def test_owning_probe_failure_reopens_each_claim_without_touching_other_scopes
    open_scope(provider_scope, evidence(provider_scope, reset_hint_seconds: 0))
    evaluation = @store.evaluate_route(
      account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
    )
    intent = probe_intent(evaluation.probe_requirements)
    admitted = nil
    @store.with_probe_intent(intent: intent) do |bindings|
      admitted = build_attempt(probe_bindings: bindings)
      @attempts[admitted.attempt_id] = admitted
    end

    result = @store.complete_probe(
      attempt: admitted,
      terminal_receipt: receipt,
      outcome: "failure"
    ).fetch(0)

    assert result.accepted?
    assert_equal "open", result.current.automatic_state
    assert_nil result.current.probe
    assert_equal 3, result.generation
    assert_equal 0, @store.inspect_scope(model_scope).generation
  end

  def test_intent_without_admitted_attempt_rolls_back_without_generation_change
    open_scope(provider_scope, evidence(provider_scope, reset_hint_seconds: 0))
    evaluation = @store.evaluate_route(
      account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
    )
    intent = probe_intent(evaluation.probe_requirements)
    crashing = store(
      fault_injector: lambda do |phase, _context|
        raise "simulated crash" if phase == :intent_persisted
      end
    )
    @attempts.delete(intent.attempt_id)

    assert_raises(RuntimeError) do
      crashing.with_probe_intent(intent: intent) { flunk "attempt must not be persisted" }
    end
    assert_equal 1, store.inspect_scope(provider_scope).generation
    store.reconcile!
    assert_equal 1, store.inspect_scope(provider_scope).generation
    assert_empty Dir.glob(File.join(@root, "intents", "*.json"))
  end

  def test_unresolved_intent_blocks_selection_and_stale_probe_claims
    open_scope(provider_scope, evidence(provider_scope, reset_hint_seconds: 0))
    evaluation = @store.evaluate_route(
      account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
    )
    intent = probe_intent(evaluation.probe_requirements)
    crashing = store(
      fault_injector: lambda do |phase, _context|
        raise "simulated crash" if phase == :intent_persisted
      end
    )

    assert_raises(RuntimeError) do
      crashing.with_probe_intent(intent: intent) { flunk "attempt must not persist" }
    end
    blocked = store.evaluate_route(
      account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
    )
    assert_equal [ "half_open_probe_owned" ],
                 blocked.blockers.map { |entry| entry.fetch("reason") }
    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      store.with_route_admission(evaluation: evaluation, intent: intent) { flunk }
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      store.with_probe_intent(intent: intent) { flunk }
    end
    competing = Hive::ProviderHealth::ProbeIntent.new(
      intent_id: "intent-2", attempt_id: intent.attempt_id,
      task_generation: intent.task_generation,
      ownership_fence: intent.ownership_fence,
      requirements: intent.requirements
    )
    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      store.with_probe_intent(intent: competing) { flunk }
    end

    store.reconcile!
    stale = Hive::ProviderHealth::ProbeRequirement.new(
      scope: provider_scope, journal_epoch: 0, observed_generation: 0
    )
    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      store.with_probe_intent(intent: probe_intent([ stale ])) { flunk }
    end
  end

  def test_restart_reconciles_a_terminal_hash_attempt_and_reopens_its_claim
    open_scope(provider_scope, evidence(provider_scope, reset_hint_seconds: 0))
    evaluation = @store.evaluate_route(
      account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
    )
    intent = probe_intent(evaluation.probe_requirements)
    crashing = store(
      fault_injector: lambda do |phase, _context|
        raise "simulated crash" if phase == :claim_persisted
      end
    )
    admitted = nil
    assert_raises(RuntimeError) do
      crashing.with_probe_intent(intent: intent) do |bindings|
        admitted = build_attempt(probe_bindings: bindings)
        @attempts[intent.attempt_id] = admitted
      end
    end
    @attempts[intent.attempt_id] = {
      "attempt_id" => admitted.attempt_id,
      "task_generation" => admitted.task_generation,
      "ownership_fence" => admitted.ownership_fence,
      "probe_bindings" => admitted.probe_bindings.map(&:to_h),
      "state" => "terminal"
    }

    result = store.reconcile!.fetch(0).fetch(0)

    assert result.accepted?
    assert_equal "probe_reconciled", result.reason
    assert_equal "open", store.inspect_scope(provider_scope).circuit.automatic_state
    assert_empty Dir.glob(File.join(@root, "intents", "*.json"))
  end

  def test_restart_recognizes_an_already_claimed_live_hash_attempt
    open_scope(provider_scope, evidence(provider_scope, reset_hint_seconds: 0))
    evaluation = @store.evaluate_route(
      account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
    )
    intent = probe_intent(evaluation.probe_requirements)
    crashing = store(
      fault_injector: lambda do |phase, _context|
        raise "simulated crash" if phase == :claim_persisted
      end
    )
    admitted = nil
    assert_raises(RuntimeError) do
      crashing.with_probe_intent(intent: intent) do |bindings|
        admitted = build_attempt(probe_bindings: bindings)
        @attempts[intent.attempt_id] = admitted
      end
    end
    @attempts[intent.attempt_id] = {
      "attempt_id" => admitted.attempt_id,
      "task_generation" => admitted.task_generation,
      "ownership_fence" => admitted.ownership_fence,
      "probe_bindings" => admitted.probe_bindings.map(&:to_h),
      "state" => "running"
    }

    result = store.reconcile!.fetch(0).fetch(0)

    assert result.duplicate?
    assert_equal "probe_already_claimed", result.reason
    assert_equal 2, store.inspect_scope(provider_scope).generation
  end

  def test_operator_mutation_reconciles_live_intent_then_requires_fresh_generation
    open_scope(provider_scope, evidence(provider_scope, reset_hint_seconds: 0))
    evaluation = @store.evaluate_route(
      account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
    )
    intent = probe_intent(evaluation.probe_requirements)
    crashing = store(
      fault_injector: lambda do |phase, _context|
        raise "simulated crash" if phase == :intent_persisted
      end
    )
    assert_raises(RuntimeError) do
      crashing.with_probe_intent(intent: intent) { flunk }
    end
    bindings = store.send(:load_intents).fetch(0).fetch(:bindings)
    @attempts[intent.attempt_id] = build_attempt(probe_bindings: bindings)
    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      @store.block(
        scope: provider_scope, expected_generation: 1,
        actor: "uid:1000", reason: "advance scope before replay"
      )
    end
    reconciled = @store.inspect_scope(provider_scope)
    blocked = @store.block(
      scope: provider_scope, expected_generation: reconciled.generation,
      actor: "uid:1000", reason: "advance scope after fresh inspection"
    )

    assert_equal 2, reconciled.generation
    assert reconciled.circuit.probe_owned?
    assert blocked.current.blocked?
    assert_nil blocked.current.probe
    assert_equal 3, blocked.generation
    assert_equal [], store.reconcile!
    assert_empty Dir.glob(File.join(@root, "intents", "*.json"))
  end

  private

  def assert_operator_intent_race_fenced(action)
    open_scope(provider_scope, evidence(provider_scope, reset_hint_seconds: 0))
    evaluation = @store.evaluate_route(
      account_id: "codex-primary", model_id: "gpt-5.6-sol", now: @clock
    )
    intent = probe_intent(evaluation.probe_requirements)
    crashing = store(
      fault_injector: lambda do |phase, _context|
        raise "simulated crash" if phase == :attempt_persisted
      end
    )
    assert_raises(RuntimeError) do
      crashing.with_probe_intent(intent: intent) do |bindings|
        @attempts[intent.attempt_id] = build_attempt(probe_bindings: bindings)
      end
    end

    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      @store.public_send(
        action,
        scope: provider_scope,
        expected_generation: 1,
        actor: "uid:1000",
        reason: "operator must re-inspect after intent reconciliation"
      )
    end

    inspection = @store.inspect_scope(provider_scope)
    assert_equal 2, inspection.generation
    assert inspection.circuit.probe_owned?
    kinds = File.readlines(journal_file(provider_scope)).map do |line|
      JSON.parse(line).fetch("kind")
    end
    assert_equal %w[evidence_opened probe_claimed], kinds
    assert_empty Dir.glob(File.join(@root, "intents", "*.json"))
  end

  def store(**options)
    Hive::ProviderHealth::Store.new(
      root: @root,
      clock: -> { @clock },
      attempt_reader: ->(id) { @attempts[id] },
      **options
    )
  end

  def open_scope(scope, signal)
    @store.apply_evidence(
      evidence: signal,
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )
  end

  def provider_scope
    @provider_scope ||= Hive::ProviderHealth::Scope.provider_account(account_id: "codex-primary")
  end

  def model_scope
    @model_scope ||= Hive::ProviderHealth::Scope.model(
      account_id: "codex-primary", model_id: "gpt-5.6-sol"
    )
  end

  def route
    @route ||= Hive::ProviderHealth::RouteIdentity.new(
      route_id: "codex-primary/gpt-5.6-sol",
      account_id: "codex-primary",
      adapter: "codex",
      launch_binding_id: "default",
      model_id: "gpt-5.6-sol"
    )
  end

  def attempt
    @attempt ||= build_attempt
  end

  def build_attempt(probe_bindings: [])
    Hive::ProviderHealth::AttemptBinding.new(
      attempt_id: "attempt-1",
      task_generation: "task-generation-1",
      ownership_fence: "fence-1",
      route: route,
      probe_bindings: probe_bindings
    )
  end

  def evidence(scope, failure_class: "provider_outage", reset_hint_seconds: 300)
    Hive::ProviderHealth::Evidence.new(
      scope: scope,
      failure_class: failure_class,
      provenance: "codex_jsonl_transport",
      route: route,
      reset_hint_seconds: reset_hint_seconds,
      source_reference: {
        "path" => "outputs/safe.json", "size" => 1, "sha256" => "a" * 64
      },
      attempt_id: "attempt-1"
    )
  end

  def probe_intent(requirements)
    Hive::ProviderHealth::ProbeIntent.new(
      intent_id: "intent-1",
      attempt_id: "attempt-1",
      task_generation: "task-generation-1",
      ownership_fence: "fence-1",
      requirements: requirements
    )
  end

  def receipt
    { "attempt_id" => "attempt-1", "receipt_version" => 1, "terminal_lease_version" => 3 }
  end

  def journal_file(scope)
    kind = scope.provider_account? ? "provider-account" : "model"
    File.join(@root, "scopes", kind, scope.key, "journal.jsonl")
  end

  def projection_file(scope)
    kind = scope.provider_account? ? "provider-account" : "model"
    File.join(@root, "scopes", kind, scope.key, "current.json")
  end
end
