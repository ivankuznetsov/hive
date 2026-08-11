require_relative "../../test_helper"
require "hive/provider_health/store"

class ProviderHealthStoreTest < Minitest::Test
  include HiveTestHelper

  def setup
    @tmp = Dir.mktmpdir("provider-health-store")
    @root = File.join(@tmp, "provider-health", "v1")
    @attempts = {}
    @clock = Time.utc(2026, 8, 10, 12)
    @store = build_store
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_evidence_open_is_idempotent_generation_fenced_and_restart_stable
    bind_attempt
    result = @store.apply_evidence(
      evidence: evidence(provider_scope),
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )
    duplicate = @store.apply_evidence(
      evidence: evidence(provider_scope),
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )

    assert result.accepted?
    assert_equal 1, result.generation
    assert duplicate.duplicate?
    assert_equal 1, duplicate.generation
    inspection = build_store.inspect_scope(provider_scope)
    assert_equal "open", inspection.circuit.automatic_state
    assert_equal result.current.to_h, inspection.circuit.to_h
    assert_equal 0o700, File.stat(@root).mode & 0o777
    state_directories.each { |path| assert_equal 0o700, File.stat(path).mode & 0o777 }
    state_files.each { |path| assert_equal 0o600, File.stat(path).mode & 0o777 }
  end

  def test_stale_and_fenced_evidence_are_bounded_nonmutating_audit_events
    bind_attempt
    stale = @store.apply_evidence(
      evidence: evidence(provider_scope),
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 4
    )
    fenced_attempt = build_attempt(ownership_fence: "stale-fence")
    fenced = @store.apply_evidence(
      evidence: evidence(model_scope, failure_class: "model_capacity"),
      attempt: fenced_attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )
    @attempts[attempt.attempt_id] = {
      "attempt_id" => attempt.attempt_id,
      "task_generation" => attempt.task_generation,
      "ownership_fence" => attempt.ownership_fence,
      "state" => "archived"
    }
    late = @store.apply_evidence(
      evidence: evidence(model_scope, failure_class: "model_capacity"),
      attempt: attempt,
      terminal_receipt: receipt.merge("terminal_lease_version" => 4),
      expected_generation: 0
    )

    assert_equal "rejected", stale.status
    assert_equal "stale_generation", stale.reason
    assert_equal 0, stale.generation
    assert_equal "rejected", fenced.status
    assert_equal "fenced_attempt", fenced.reason
    assert_equal 0, fenced.generation
    assert_equal "late_receipt", late.reason
    assert_equal 0, late.generation
    refute_includes all_state_bytes, "stale-fence"
  end

  def test_provider_and_model_composition_and_operator_actions_are_scope_safe
    bind_attempt
    @store.apply_evidence(
      evidence: evidence(model_scope, failure_class: "model_capacity"),
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )

    same_model = @store.evaluate_route(account_id: "codex-primary", model_id: "gpt-5.6-sol")
    sibling = @store.evaluate_route(account_id: "codex-primary", model_id: "gpt-5.6-terra")
    assert_equal [ "circuit_cooldown" ], same_model.blockers.map { |entry| entry.fetch("reason") }
    assert sibling.eligible?

    blocked = @store.block(
      scope: provider_scope,
      expected_generation: 0,
      actor: "uid:1000",
      reason: "planned maintenance"
    )
    unblocked = @store.unblock(
      scope: provider_scope,
      expected_generation: 1,
      actor: "uid:1000",
      reason: "maintenance complete"
    )
    reset_model = @store.reset(
      scope: model_scope,
      expected_generation: 1,
      actor: "uid:1000",
      reason: "verified provider recovery"
    )

    assert_equal 1, blocked.generation
    assert blocked.current.blocked?
    assert_equal 2, unblocked.generation
    refute unblocked.current.blocked?
    assert_equal "closed", reset_model.current.automatic_state
    assert_equal 2, reset_model.generation
    assert_equal 2, @store.inspect_scope(provider_scope).generation
  end

  def test_operator_generation_cas_serializes_concurrent_mutations_once
    gate = Queue.new
    results = 8.times.map do
      Thread.new do
        gate.pop
        begin
          @store.block(
            scope: provider_scope,
            expected_generation: 0,
            actor: "uid:1000",
            reason: "planned maintenance"
          ).status
        rescue Hive::ProviderHealth::StaleGeneration
          "stale"
        end
      end
    end
    8.times { gate << true }
    statuses = results.map(&:value)

    assert_equal 1, statuses.count("accepted")
    assert_equal 7, statuses.count("stale")
    assert_equal 1, @store.inspect_scope(provider_scope).generation
    assert_equal 1, journal_events(provider_scope).count { |event| event.fetch("kind") == "manual_blocked" }
  end

  def test_exact_model_reset_preserves_manual_block_until_explicit_unblock
    blocked = @store.block(
      scope: model_scope,
      expected_generation: 0,
      actor: "uid:1000",
      reason: "disable exact model route"
    )
    reset = @store.reset(
      scope: model_scope,
      expected_generation: 1,
      actor: "uid:1000",
      reason: "clear observed model health"
    )
    unblocked = @store.unblock(
      scope: model_scope,
      expected_generation: 2,
      actor: "uid:1000",
      reason: "restore exact model route"
    )

    assert blocked.current.blocked?
    assert reset.current.blocked?
    assert_equal "closed", reset.current.automatic_state
    refute unblocked.current.blocked?
    assert_equal 3, unblocked.generation
  end

  def test_secret_canaries_never_enter_state_audit_or_fingerprint
    bind_attempt
    unsafe_reference = reference.merge("message" => "secret-canary")
    assert_raises(Hive::ProviderHealth::InvalidEvidence) do
      evidence(provider_scope, source_reference: unsafe_reference)
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      @store.block(
        scope: provider_scope,
        expected_generation: 0,
        actor: "uid:1000",
        reason: "api_key=secret-canary"
      )
    end

    @store.apply_evidence(
      evidence: evidence(provider_scope),
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )
    refute_includes all_state_bytes, "secret-canary"
  end

  def test_typed_mutation_receipt_and_cooldown_validation_fail_closed
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      @store.apply_evidence(
        evidence: Object.new, attempt: Object.new,
        terminal_receipt: {}, expected_generation: 0
      )
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      @store.complete_probe(attempt: Object.new, terminal_receipt: {}, outcome: "success")
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      @store.complete_probe(attempt: attempt, terminal_receipt: receipt, outcome: "unknown")
    end

    bind_attempt
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      @store.apply_evidence(
        evidence: evidence(provider_scope), attempt: attempt,
        terminal_receipt: receipt.merge("extra" => true), expected_generation: 0
      )
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      @store.apply_evidence(
        evidence: evidence(provider_scope), attempt: attempt,
        terminal_receipt: receipt.merge("attempt_id" => "other-attempt"),
        expected_generation: 0
      )
    end

    incomplete = {}
    incomplete.define_singleton_method(:keys) do
      %w[attempt_id receipt_version terminal_lease_version]
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      @store.send(:normalize_terminal_receipt, incomplete, attempt_id: attempt.attempt_id)
    end

    invalid_cooldown = build_store(cooldown_resolver: ->(_signal) { 99_999_999 })
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      invalid_cooldown.apply_evidence(
        evidence: evidence(provider_scope), attempt: attempt,
        terminal_receipt: receipt, expected_generation: 0
      )
    end
  end

  def test_route_admission_rejects_invalid_or_stale_probe_observations
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      @store.with_route_admission(evaluation: Object.new) { flunk }
    end

    closed = @store.evaluate_route(
      account_id: route.account_id, model_id: route.model_id, now: @clock
    )
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      @store.with_route_admission(evaluation: closed, intent: Object.new) { flunk }
    end

    bind_attempt
    @store.apply_evidence(
      evidence: evidence(provider_scope, reset_hint_seconds: 0), attempt: attempt,
      terminal_receipt: receipt, expected_generation: 0
    )
    half_open = @store.evaluate_route(
      account_id: route.account_id, model_id: route.model_id, now: @clock
    )
    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      @store.with_route_admission(evaluation: half_open) { flunk }
    end

    changed_requirement = Hive::ProviderHealth::ProbeRequirement.new(
      scope: provider_scope, journal_epoch: 0, observed_generation: 0
    )
    mismatch = probe_intent(requirements: [ changed_requirement ])
    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      @store.with_route_admission(evaluation: half_open, intent: mismatch) { flunk }
    end

    inspections = [ provider_scope, model_scope ].map { |scope| @store.inspect_scope(scope) }
    provider = inspections.fetch(0)
    stale_requirement = Hive::ProviderHealth::ProbeRequirement.new(
      scope: provider_scope, journal_epoch: provider.journal_epoch,
      observed_generation: provider.generation
    )
    @store.reset(
      scope: provider_scope, expected_generation: provider.generation,
      actor: "uid:1000", reason: "close circuit before stale snapshot proof"
    )
    closed_inspections = [ provider_scope, model_scope ].map { |scope| @store.inspect_scope(scope) }
    false_requirement = Hive::ProviderHealth::ProbeRequirement.new(
      scope: provider_scope,
      journal_epoch: closed_inspections.fetch(0).journal_epoch,
      observed_generation: closed_inspections.fetch(0).generation
    )
    invalid_evaluation = Hive::ProviderHealth::RouteEvaluation.new(
      status: "eligible", inspections: closed_inspections, blockers: [],
      probe_requirements: [ false_requirement ]
    )
    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      @store.with_route_admission(
        evaluation: invalid_evaluation,
        intent: probe_intent(requirements: [ false_requirement ])
      ) { flunk }
    end
    assert_equal 1, stale_requirement.observed_generation
  end

  def test_unavailable_storage_and_corrupt_scope_evaluations_are_bounded
    unsafe = build_store
    unsafe.define_singleton_method(:with_mutation_lock) do |&block|
      block
      raise Hive::ManagedDirectory::UnsafeError, "unsafe"
    end
    inspection = unsafe.inspect_scope(provider_scope)
    assert inspection.unavailable?
    evaluation = unsafe.evaluate_route(
      account_id: route.account_id, model_id: route.model_id
    )
    assert_equal %w[health_state_unavailable health_state_unavailable],
                 evaluation.blockers.map { |entry| entry.fetch("reason") }

    corruption_class = Hive::ProviderHealth::Store.const_get(:JournalCorruption, false)
    corruption = corruption_class.new(
      scope: provider_scope, bytes: "bad".b,
      last_circuit: Hive::ProviderHealth::Circuit.closed(scope: provider_scope)
    )
    corrupting = build_store
    corrupting.define_singleton_method(:with_mutation_lock) { |&_block| raise corruption }
    failed = corrupting.evaluate_route(
      account_id: route.account_id, model_id: route.model_id
    )
    assert_equal [ "health_state_unavailable" ],
                 failed.blockers.map { |entry| entry.fetch("reason") }
  end

  def test_defensive_generation_and_attempt_reader_failures_are_nonmutating
    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      @store.block(
        scope: provider_scope, expected_generation: "invalid",
        actor: "uid:1000", reason: "validate generation input"
      )
    end

    failing_reader = build_store(attempt_reader: ->(_id) { raise "reader failure" })
    rejected = failing_reader.apply_evidence(
      evidence: evidence(provider_scope), attempt: attempt,
      terminal_receipt: receipt, expected_generation: "invalid"
    )
    assert_equal "stale_generation", rejected.reason

    rejected = failing_reader.apply_evidence(
      evidence: evidence(model_scope, failure_class: "model_capacity"), attempt: attempt,
      terminal_receipt: receipt, expected_generation: 0
    )
    assert_equal "fenced_attempt", rejected.reason
  end

  def test_unknown_operator_action_and_stale_corruption_token_are_rejected
    replay = @store.send(
      :load_replay, provider_scope, recover_torn: true, publish_projection: false
    )
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      @store.send(
        :append_operator_transition, replay,
        action: "future", actor: "uid:1000", reason: "unsupported action"
      )
    end

    bind_attempt
    @store.apply_evidence(
      evidence: evidence(provider_scope), attempt: attempt,
      terminal_receipt: receipt, expected_generation: 0
    )
    File.binwrite(journal_file(provider_scope), "invalid\n" + File.binread(journal_file(provider_scope)))
    unavailable = @store.inspect_scope(provider_scope)
    stale = Hive::ProviderHealth::CorruptionToken.new(
      scope: provider_scope,
      journal_epoch: unavailable.corruption_token.journal_epoch,
      corruption_fingerprint: "b" * 64,
      last_verified_generation: unavailable.corruption_token.last_verified_generation
    )
    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      @store.reset(
        scope: provider_scope, corruption_token: stale,
        actor: "uid:1000", reason: "reject stale corruption token"
      )
    end
  end

  def test_journal_parser_distinguishes_torn_tail_from_parseable_or_interior_corruption
    bind_attempt
    @store.apply_evidence(
      evidence: evidence(provider_scope), attempt: attempt,
      terminal_receipt: receipt, expected_generation: 0
    )
    @store.block(
      scope: provider_scope, expected_generation: 1,
      actor: "uid:1000", reason: "preserve verified block"
    )
    @store.unblock(
      scope: provider_scope, expected_generation: 2,
      actor: "uid:1000", reason: "create parseable final record"
    )
    valid = File.binread(journal_file(provider_scope))

    File.binwrite(journal_file(provider_scope), valid.chomp)
    unavailable = @store.inspect_scope(provider_scope)
    assert unavailable.unavailable?
    assert_equal 2, unavailable.corruption_token.last_verified_generation
    repaired = @store.reset(
      scope: provider_scope, corruption_token: unavailable.corruption_token,
      actor: "uid:1000", reason: "repair parseable torn record"
    )
    assert repaired.current.blocked?

    File.binwrite(journal_file(provider_scope), valid + "{")
    corruption_class = Hive::ProviderHealth::Store.const_get(:JournalCorruption, false)
    assert_raises(corruption_class) do
      @store.send(
        :load_replay, provider_scope, recover_torn: false, publish_projection: false
      )
    end

    event = JSON.parse(valid.lines.first)
    event["journal_epoch"] = 1
    File.binwrite(journal_file(provider_scope), "#{JSON.generate(event)}\n")
    assert @store.inspect_scope(provider_scope).unavailable?
  end

  def test_journal_reader_rethrows_configuration_and_sanitizes_unexpected_failures
    directory = @store.instance_variable_get(:@directory)
    with_replaced_singleton_method(
      directory, :read, ->(*, **) { raise Hive::ConfigError, "configuration failure" }
    ) do
      assert_raises(Hive::ConfigError) do
        @store.send(
          :load_replay, provider_scope, recover_torn: true, publish_projection: false
        )
      end
    end

    corruption_class = Hive::ProviderHealth::Store.const_get(:JournalCorruption, false)
    with_replaced_singleton_method(
      directory, :read, ->(*, **) { raise "unexpected reader failure" }
    ) do
      error = assert_raises(corruption_class) do
        @store.send(
          :load_replay, provider_scope, recover_torn: true, publish_projection: false
        )
      end
      assert_equal "provider-health journal is unavailable", error.message
    end
  end

  def test_corrupt_single_scope_and_invalid_intent_files_fail_route_evaluation_closed
    FileUtils.mkdir_p(File.dirname(journal_file(model_scope)))
    File.binwrite(journal_file(model_scope), "invalid\n")
    evaluation = @store.evaluate_route(
      account_id: route.account_id, model_id: route.model_id
    )
    assert_equal [ "health_state_unavailable" ],
                 evaluation.blockers.map { |entry| entry.fetch("reason") }

    FileUtils.rm_f(journal_file(model_scope))
    File.binwrite(File.join(@root, "intents", "bad.json"), "{")
    unavailable = @store.evaluate_route(
      account_id: route.account_id, model_id: route.model_id
    )
    assert_equal %w[health_state_unavailable health_state_unavailable],
                 unavailable.blockers.map { |entry| entry.fetch("reason") }
  end

  def test_probe_intent_parser_rejects_every_untrusted_shape
    requirement = {
      "scope" => provider_scope.to_h,
      "journal_epoch" => 0,
      "observed_generation" => 0
    }
    binding = requirement.merge(
      "claim_generation" => 1,
      "attempt_id" => attempt.attempt_id,
      "task_generation" => attempt.task_generation,
      "ownership_fence" => attempt.ownership_fence
    )
    payload = {
      "schema" => "hive-provider-health-probe-intent",
      "schema_version" => 1,
      "intent" => {
        "intent_id" => "intent-1", "attempt_id" => attempt.attempt_id,
        "task_generation" => attempt.task_generation,
        "ownership_fence" => attempt.ownership_fence,
        "requirements" => [ requirement ]
      },
      "bindings" => [ binding ]
    }
    parsed = @store.send(:parse_intent, JSON.generate(payload))
    assert_equal "intent-1", parsed.fetch(:intent).intent_id

    malformed = []
    malformed << payload.merge("schema_version" => 2)
    malformed << Marshal.load(Marshal.dump(payload)).tap do |copy|
      copy.fetch("intent")["future"] = true
    end
    malformed << Marshal.load(Marshal.dump(payload)).tap do |copy|
      copy.dig("intent", "requirements", 0)["future"] = true
    end
    malformed << payload.merge(
      "bindings" => [ binding.merge("scope" => model_scope.to_h) ]
    )
    malformed << payload.merge(
      "bindings" => [ binding.merge("future" => true) ]
    )
    malformed.each do |candidate|
      assert_raises(Hive::ProviderHealth::InvalidMutation) do
        @store.send(:parse_intent, JSON.generate(candidate))
      end
    end
  end

  def test_route_admission_rejects_an_open_scope_before_its_probe_window
    bind_attempt
    @store.apply_evidence(
      evidence: evidence(provider_scope, reset_hint_seconds: 300), attempt: attempt,
      terminal_receipt: receipt, expected_generation: 0
    )
    inspections = [ provider_scope, model_scope ].map { |scope| @store.inspect_scope(scope) }
    requirement = Hive::ProviderHealth::ProbeRequirement.new(
      scope: provider_scope, journal_epoch: inspections.fetch(0).journal_epoch,
      observed_generation: inspections.fetch(0).generation
    )
    evaluation = Hive::ProviderHealth::RouteEvaluation.new(
      status: "eligible", inspections: inspections, blockers: [],
      probe_requirements: [ requirement ]
    )

    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      @store.with_route_admission(
        evaluation: evaluation, intent: probe_intent(requirements: [ requirement ])
      ) { flunk }
    end
  end

  def test_mutation_lock_converts_journal_corruption_to_bounded_unavailability
    bind_attempt
    FileUtils.mkdir_p(File.dirname(journal_file(provider_scope)))
    File.binwrite(journal_file(provider_scope), "invalid\n")

    error = assert_raises(Hive::ProviderHealth::Unavailable) do
      @store.apply_evidence(
        evidence: evidence(provider_scope), attempt: attempt,
        terminal_receipt: receipt, expected_generation: 0
      )
    end
    assert_equal "health_state_unavailable", error.message
  end

  def test_writer_rejects_the_event_after_the_reader_limit
    replay_class = Hive::ProviderHealth::Store.const_get(:Replay, false)
    existing = Struct.new(:idempotency_key).new("b" * 64)
    replay = replay_class.new(
      circuit: Hive::ProviderHealth::Circuit.closed(scope: provider_scope),
      events: Array.new(Hive::ProviderHealth::Store::MAX_JOURNAL_EVENTS, existing),
      bytes: "".b,
      existed: false
    )

    event = Hive::ProviderHealth::Event.new(
      event_id: "event-over-limit",
      sequence: Hive::ProviderHealth::Store::MAX_JOURNAL_EVENTS + 1,
      scope: provider_scope,
      journal_epoch: 0,
      kind: "evidence_rejected",
      occurred_at: @clock,
      idempotency_key: "a" * 64,
      expected_generation: 0,
      previous_generation: 0,
      resulting_generation: 0,
      payload: { "reason" => "stale_generation" }
    )
    error = assert_raises(Hive::ProviderHealth::Unavailable) do
      @store.send(:persist_event, replay, event)
    end
    assert_equal "provider-health journal is full", error.message
  end

  private

  def build_store(**options)
    Hive::ProviderHealth::Store.new(
      root: @root,
      clock: -> { @clock },
      attempt_reader: ->(id) { @attempts[id] },
      **options
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

  def build_attempt(ownership_fence: "fence-1", probe_bindings: [])
    Hive::ProviderHealth::AttemptBinding.new(
      attempt_id: "attempt-1",
      task_generation: "task-generation-1",
      ownership_fence: ownership_fence,
      route: route,
      probe_bindings: probe_bindings
    )
  end

  def bind_attempt(value = attempt)
    @attempts[value.attempt_id] = value
  end

  def evidence(scope, failure_class: "provider_outage", source_reference: reference,
               reset_hint_seconds: 300)
    Hive::ProviderHealth::Evidence.new(
      scope: scope,
      failure_class: failure_class,
      provenance: "codex_jsonl_transport",
      route: route,
      reset_hint_seconds: reset_hint_seconds,
      source_reference: source_reference,
      attempt_id: "attempt-1"
    )
  end

  def reference
    { "path" => "outputs/safe.json", "size" => 12, "sha256" => "a" * 64 }
  end

  def receipt
    { "attempt_id" => "attempt-1", "receipt_version" => 1, "terminal_lease_version" => 3 }
  end

  def probe_intent(requirements:)
    Hive::ProviderHealth::ProbeIntent.new(
      intent_id: "intent-1", attempt_id: attempt.attempt_id,
      task_generation: attempt.task_generation,
      ownership_fence: attempt.ownership_fence,
      requirements: requirements
    )
  end

  def state_files
    Dir.glob(File.join(@root, "**", "*")).select { |path| File.file?(path) }
  end

  def state_directories
    Dir.glob(File.join(@root, "**", "*")).select { |path| File.directory?(path) }
  end

  def all_state_bytes
    state_files.map { |path| File.binread(path) }.join
  end

  def journal_events(scope)
    path = journal_file(scope)
    File.readlines(path).map { |line| JSON.parse(line) }
  end

  def journal_file(scope)
    kind = scope.provider_account? ? "provider-account" : "model"
    File.join(@root, "scopes", kind, scope.key, "journal.jsonl")
  end
end
