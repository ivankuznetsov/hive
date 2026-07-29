require "test_helper"
require "hive/modules/migration/effect_admission"
require "hive/modules/migration/effect_delivery"
require "hive/modules/migration/effect_sender"

class ModulesMigrationEffectDeliveryCollaboratorsTest < Minitest::Test
  Intent = Data.define(
    :occurrence_id,
    :claim_generation,
    :capability,
    :sink,
    :target,
    :scope
  )
  Receipt = Data.define(:receipt_id, :status, :outcome)

  class DeliveryError < StandardError
    attr_reader :reason, :receipt

    def initialize(reason, receipt)
      @reason = reason
      @receipt = receipt
      super(reason)
    end
  end

  class NotDelivered < StandardError; end

  class LifecycleStore
    Configuration = Data.define(:generation, :grants)

    attr_accessor :selection, :configuration_value

    def with_admission(_name)
      yield selection
    end

    def configuration(*)
      configuration_value
    end
  end

  class DeliveryStore
    attr_accessor :state, :receipt
    attr_reader :calls

    def initialize
      @calls = []
      @state = { "state" => "prepared" }
    end

    def prepare_effect!(intent, **options)
      calls << [ :prepare, intent, options ]
    end

    def with_effect_sender_lock(intent)
      calls << [ :sender_lock, intent ]
      yield
    end

    def mark_dispatch_uncertain!(intent, **options)
      calls << [ :fence, intent, options ]
      @state = { "state" => "dispatch_uncertain" }
    end

    def reset_effect_prepared!(intent, **options)
      calls << [ :reset, intent, options ]
      @state = { "state" => "prepared" }
    end

    def settle_effect!(intent, **options)
      calls << [ :settled, intent, options ]
      @receipt = Receipt.new(
        receipt_id: "receipt-1",
        status: options.fetch(:status),
        outcome: options.fetch(:outcome)
      )
      @state = {
        "state" => @receipt.status,
        "terminal_receipt_id" => @receipt.receipt_id,
        "outcome" => @receipt.outcome
      }
      @receipt
    end

    def effect_state(_intent)
      state
    end

    def effect_receipt(*)
      receipt
    end

    def drain_occurrence_outbox!(*, **)
      calls << [ :drain ]
    end
  end

  class EvidenceStore
    attr_reader :receipts

    def initialize
      @receipts = []
    end

    def append_receipt(receipt)
      receipts << receipt
    end
  end

  class ReceiptLedger
    attr_accessor :terminal
    attr_reader :calls

    def initialize
      @calls = []
    end

    def terminal_result(intent)
      calls << [ :terminal_result, intent ]
      terminal
    end

    def replay_terminal(intent, result = nil)
      calls << [ :replay, intent, result ]
      :terminal
    end

    def drain(intent)
      calls << [ :drain, intent ]
    end

    def result_from_receipt(receipt)
      receipt.status.to_sym
    end
  end

  def test_lifecycle_admission_revalidates_generation_and_grants
    lifecycle = LifecycleStore.new
    lifecycle.selection = {
      "installed" => true,
      "enabled" => true,
      "active" => {
        "source_commit" => "a" * 40,
        "configuration_digest" => "b" * 64
      }
    }
    lifecycle.configuration_value = LifecycleStore::Configuration.new(
      generation: { "source_commit" => "a" * 40 },
      grants: capability_grants
    )
    admission = admission_with(
      lifecycle,
      module_execution: {
        module: "patrol",
        generation: "a" * 40,
        configuration_digest: "b" * 64
      }
    )
    result = admission.with_live_authorization(
      intent,
      on_denied: ->(reason) { "denied:#{reason}" }
    ) { "authorized" }
    assert_equal "authorized", result

    lifecycle.selection["active"]["source_commit"] = "c" * 40
    result = admission.with_live_authorization(
      intent,
      on_denied: ->(reason) { reason }
    ) { flunk("revoked generation must not run") }
    assert_equal "module_generation_revoked", result

    lifecycle.selection["active"]["source_commit"] = "a" * 40
    lifecycle.configuration_value = LifecycleStore::Configuration.new(
      generation: { "source_commit" => "c" * 40 },
      grants: capability_grants
    )
    result = admission.with_live_authorization(
      intent,
      on_denied: ->(reason) { reason }
    ) { flunk("mismatched configuration must not run") }
    assert_equal "module_generation_revoked", result

    assert_raises(Hive::ConfigError) do
      admission_with(
        lifecycle,
        module_execution: { module: "patrol" }
      )
    end
    assert_raises(Hive::ConfigError) do
      admission_with(lifecycle, module_execution: Object.new)
    end
  end

  def test_sender_reconcile_only_protocol_handles_every_recovery_state
    store = DeliveryStore.new
    ledger = ReceiptLedger.new
    sender = sender_with(store, ledger, retry_safe: true)

    ledger.terminal = true
    assert_equal :terminal,
                 sender.reconcile_observed(intent, ->(*) { {} })
    assert_equal(
      [
        [ :terminal_result, intent ],
        [ :replay, intent, true ]
      ],
      ledger.calls
    )
    ledger.calls.clear
    ledger.terminal = nil

    result = sender.reconcile_observed(
      intent,
      ->(*) do
        {
          "status" => "absent",
          "outcome" => { "remote" => "absent" }
        }
      end
    )
    assert_equal :retry_safe, result.status
    assert_includes store.calls.map(&:first), :fence
    assert_includes store.calls.map(&:first), :reset

    store.state = { "state" => "dispatch_uncertain" }
    assert_equal(
      :reconciled,
      sender.reconcile_observed(
        intent,
        ->(*) do
          {
            "status" => "matched",
            "outcome" => { "remote" => "found" }
          }
        end
      )
    )

    store.state = { "state" => "unknown" }
    error = assert_raises(DeliveryError) do
      sender.reconcile_observed(intent, ->(*) { {} })
    end
    assert_match(/unrecognized/, error.reason)
  end

  def test_sender_delivery_fail_closed_paths_are_explicit
    store = DeliveryStore.new
    ledger = ReceiptLedger.new
    sender = sender_with(store, ledger)

    ledger.terminal = true
    assert_equal :terminal,
                 sender.deliver_or_reconcile(
                   intent, nil, -> { {} }
                 )
    ledger.terminal = nil

    store.state = { "state" => "unknown" }
    assert_raises(DeliveryError) do
      sender.deliver_or_reconcile(intent, nil, -> { {} })
    end

    store.state = {}
    assert_raises(DeliveryError) do
      sender.deliver_or_reconcile(intent, nil, -> { {} })
    end

    store.state = { "state" => "prepared" }
    assert_raises(Hive::ConfigError) do
      sender.deliver_or_reconcile(intent, nil, -> { [] })
    end

    store.state = { "state" => "dispatch_uncertain" }
    ambiguous = assert_raises(DeliveryError) do
      sender.deliver_or_reconcile(
        intent, ->(*) { raise "remote unavailable" }, -> { {} }
      )
    end
    assert_equal "remote_identity_ambiguous", ambiguous.reason

    store.state = { "state" => "dispatch_uncertain" }
    absent = assert_raises(DeliveryError) do
      sender.deliver_or_reconcile(
        intent,
        ->(*) { { "status" => "absent", "outcome" => {} } },
        -> { {} }
      )
    end
    assert_equal "remote_absence_not_retry_safe", absent.reason

    store.state = { "state" => "dispatch_uncertain" }
    policy_failure = assert_raises(DeliveryError) do
      sender_with(
        store,
        ledger,
        retry_safe: ->(*) { raise "policy unavailable" }
      ).deliver_or_reconcile(
        intent,
        ->(*) { { "status" => "absent", "outcome" => {} } },
        -> { {} }
      )
    end
    assert_equal "remote_absence_not_retry_safe", policy_failure.reason
  end

  def test_retry_safe_absence_resets_then_redispatches_once
    store = DeliveryStore.new
    store.state = { "state" => "dispatch_uncertain" }
    calls = 0
    result = sender_with(
      store, ReceiptLedger.new, retry_safe: true
    ).deliver_or_reconcile(
      intent,
      ->(*) do
        {
          "status" => "absent",
          "outcome" => { "remote" => "absent" }
        }
      end,
      lambda do
        calls += 1
        { "remote" => "created" }
      end
    )

    assert_equal :committed, result
    assert_equal 1, calls
    assert_equal %i[sender_lock reset fence settled],
                 store.calls.map(&:first)
  end

  def test_default_admission_dependencies_and_delivery_validation_are_explicit
    capture = patrol_capture
    admission = Hive::Modules::Migration::EffectAdmission.new(
      module_name: "patrol",
      product_label: "patrol",
      config_key: "patrol",
      project_root: "/tmp/project",
      hive_state_path: "/tmp/project/.hive-state",
      capture: capture,
      authority: "legacy",
      migration_lock: ->(&block) { block.call },
      ownership_loader: -> {
        { "owner" => "legacy", "epoch" => 1, "admission" => true }
      }
    )
    factory = admission.instance_variable_get(:@lifecycle_store_factory)
    managed_store = factory.call("/tmp/project")
    assert_equal "Hive::ModulePackage::ManagedStore", managed_store.class.name

    common = {
      module_name: "patrol",
      product_label: "patrol",
      config_key: "patrol",
      project_root: "/tmp/project",
      hive_state_path: "/tmp/project/.hive-state",
      evidence_store: Object.new,
      delivery_store: DeliveryStore.new,
      denied_error: DeliveryError,
      reconciliation_error: DeliveryError,
      migration_lock: ->(&block) { block.call },
      ownership_loader: -> {
        { "owner" => "legacy", "epoch" => 1, "admission" => true }
      }
    }
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::EffectDelivery.new(
        **common, capture: Object.new, authority: "legacy"
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::EffectDelivery.new(
        **common, capture: capture, authority: "invalid"
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::EffectDelivery.new(
        **common,
        capture: capture,
        authority: "legacy",
        retry_safe_sinks: [ "unknown" ]
      )
    end

    delivery = Hive::Modules::Migration::EffectDelivery.new(
      **common,
      capture: capture,
      authority: "legacy",
      config_loader: ->(_root) { { "patrol" => {} } }
    )
    assert_raises(ArgumentError) do
      delivery.reconcile!(
        sink: "state",
        target: "target",
        idempotency_key: "key",
        capability: "filesystem_write"
      )
    end
  end

  def test_receipt_replay_and_unsafe_absence_preserve_canonical_evidence
    store = DeliveryStore.new
    store.state = {
      "state" => "denied",
      "terminal_receipt_id" => "receipt-1",
      "outcome" => { "reason" => "revoked" }
    }
    store.receipt = Receipt.new(
      receipt_id: "receipt-1",
      status: "denied",
      outcome: { "reason" => "revoked" }
    )
    ledger = Hive::Modules::Migration::EffectReceiptLedger.new(
      delivery_store: store,
      evidence_store: Object.new,
      denied_error: DeliveryError,
      clock: -> { Time.utc(2026, 7, 28, 18) }
    )
    denied = assert_raises(DeliveryError) do
      ledger.terminal_result(intent)
    end
    assert_equal "revoked", denied.reason

    store.state = {
      "state" => "committed",
      "terminal_receipt_id" => "receipt-1",
      "outcome" => { "reason" => "revoked" }
    }
    assert_raises(Hive::ConfigError) do
      ledger.terminal_result(intent)
    end

    receipt_ledger = ReceiptLedger.new
    store.state = { "state" => "dispatch_uncertain" }
    assert_nil ledger.replay_terminal(intent)
    refute_includes store.calls.map(&:first), :drain
    absence = assert_raises(DeliveryError) do
      sender_with(store, receipt_ledger).deliver_or_reconcile(
        intent,
        ->(*) { { "status" => "absent", "outcome" => {} } },
        -> { {} }
      )
    end
    assert_equal "remote_absence_not_retry_safe", absence.reason

    sender = sender_with(store, receipt_ledger)
    assert_equal(
      { "status" => "ambiguous", "outcome" => {} },
      sender.send(:exact_reconciliation, intent, nil)
    )
    assert_equal(
      { "status" => "ambiguous", "outcome" => {} },
      sender.send(:exact_reconciliation, intent, ->(*) { [] })
    )
  end

  def test_default_config_and_diagnostic_fallback_revalidate_authority
    capture = Data.define(:owner, :owner_epoch).new(
      owner: "legacy", owner_epoch: 7
    )
    common = {
      module_name: "patrol",
      product_label: "patrol",
      config_key: "patrol",
      project_root: "/tmp/project",
      hive_state_path: "/tmp/project/.hive-state",
      capture: capture,
      authority: "legacy",
      migration_lock: ->(&block) { block.call },
      ownership_loader: lambda do
        { "owner" => "legacy", "epoch" => 7, "admission" => true }
      end
    }
    Dir.mktmpdir do |project_root|
      admission = Hive::Modules::Migration::EffectAdmission.new(
        **common.merge(
          project_root: project_root,
          hive_state_path: File.join(project_root, ".hive-state")
        )
      )
      result = admission.with_live_authorization(
        intent,
        on_denied: ->(reason) { reason }
      ) { flunk("default disabled patrol must not authorize") }
      assert_equal "configuration_disabled", result
    end

    admission = Hive::Modules::Migration::EffectAdmission.new(
      **common,
      config_loader: ->(*) { raise "configuration unavailable" },
      diagnostic_transition: true
    )
    result = admission.with_live_authorization(
      intent,
      on_denied: ->(reason) { flunk("unexpected denial: #{reason}") }
    ) { :diagnostic_authorized }
    assert_equal :diagnostic_authorized, result
  end

  def test_default_clock_shadow_and_terminal_replay_are_durable
    capture = patrol_capture
    evidence = EvidenceStore.new
    shadow_store = DeliveryStore.new
    shadow = Hive::Modules::Migration::EffectDelivery.new(
      module_name: "patrol",
      product_label: "patrol",
      config_key: "patrol",
      project_root: "/tmp/project",
      hive_state_path: "/tmp/project/.hive-state",
      capture: capture,
      authority: "shadow",
      evidence_store: evidence,
      delivery_store: shadow_store,
      denied_error: DeliveryError,
      reconciliation_error: DeliveryError,
      migration_lock: ->(&block) { block.call },
      ownership_loader: lambda do
        { "owner" => "legacy", "epoch" => 1, "admission" => true }
      end,
      config_loader: ->(*) { { "patrol" => {} } }
    )
    denied = assert_raises(DeliveryError) do
      shadow.perform!(
        sink: "state",
        target: "target",
        idempotency_key: "shadow-attempt",
        capability: "filesystem_write"
      ) { flunk("shadow authority must never invoke the effect") }
    end
    assert_equal "shadow_mutation_forbidden", denied.reason
    assert_equal 1, evidence.receipts.length

    store = DeliveryStore.new
    store.state = {
      "state" => "committed",
      "terminal_receipt_id" => "receipt-1",
      "outcome" => { "transition_status" => "present" }
    }
    store.receipt = Receipt.new(
      receipt_id: "receipt-1",
      status: "committed",
      outcome: { "transition_status" => "present" }
    )
    delivery = Hive::Modules::Migration::EffectDelivery.new(
      module_name: "patrol",
      product_label: "patrol",
      config_key: "patrol",
      project_root: "/tmp/project",
      hive_state_path: "/tmp/project/.hive-state",
      capture: capture,
      authority: "legacy",
      evidence_store: evidence,
      delivery_store: store,
      denied_error: DeliveryError,
      reconciliation_error: DeliveryError,
      migration_lock: ->(&block) { block.call },
      ownership_loader: lambda do
        { "owner" => "legacy", "epoch" => 1, "admission" => true }
      end,
      config_loader: ->(*) { { "patrol" => {} } }
    )
    result = delivery.reconcile!(
      sink: "state",
      target: "target",
      idempotency_key: "terminal",
      capability: "filesystem_write"
    ) { flunk("terminal replay must not reconcile remotely") }
    assert_equal :committed, result.status
  end

  def test_delivery_redacts_closed_outcomes_before_settlement_and_replay
    capture = patrol_capture
    store = DeliveryStore.new
    delivery = Hive::Modules::Migration::EffectDelivery.new(
      module_name: "patrol",
      product_label: "patrol",
      config_key: "patrol",
      project_root: "/tmp/project",
      hive_state_path: "/tmp/project/.hive-state",
      capture: capture,
      authority: "legacy",
      evidence_store: EvidenceStore.new,
      delivery_store: store,
      denied_error: DeliveryError,
      reconciliation_error: DeliveryError,
      migration_lock: ->(&block) { block.call },
      ownership_loader: lambda do
        { "owner" => "legacy", "epoch" => 1, "admission" => true }
      end,
      config_loader: ->(*) { { "patrol" => { "enabled" => true } } },
      clock: -> { Time.utc(2026, 7, 28, 18) }
    )
    token = "github_pat_#{'b' * 24}"
    attributes = {
      sink: "state",
      target: "state",
      idempotency_key: "redacted-settlement",
      capability: "filesystem_write"
    }

    result = delivery.perform!(**attributes) do
      {
        "reason" => "found #{token}"
      }
    end
    replay = delivery.perform!(**attributes) do
      flunk("terminal replay must not invoke the effect")
    end

    redacted = "[REDACTED:github_fine_grained_pat]"
    expected = {
      "reason" => "found #{redacted}"
    }
    assert_equal expected, result.outcome
    assert_equal expected, store.state.fetch("outcome")
    assert_equal result.receipt, replay.receipt
    refute_includes store.calls.to_s, token
  end

  def test_recovery_reconciliation_requires_a_block_rejects_foreign_intents_and_replays_terminal_receipts
    capture = patrol_capture
    store = DeliveryStore.new
    store.state = {
      "state" => "committed",
      "terminal_receipt_id" => "receipt-1",
      "outcome" => { "transition_status" => "present" }
    }
    store.receipt = Receipt.new(
      receipt_id: "receipt-1", status: "committed",
      outcome: { "transition_status" => "present" }
    )
    delivery = Hive::Modules::Migration::EffectDelivery.new(
      module_name: "patrol", product_label: "patrol", config_key: "patrol",
      project_root: "/tmp/project", hive_state_path: "/tmp/project/.hive-state",
      capture: capture, authority: "legacy", evidence_store: EvidenceStore.new,
      delivery_store: store, denied_error: DeliveryError,
      reconciliation_error: DeliveryError, migration_lock: ->(&block) { block.call },
      ownership_loader: -> { { "owner" => "legacy", "epoch" => 1, "admission" => true } },
      config_loader: ->(*) { { "patrol" => {} } }
    )
    valid = Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol", occurrence_id: capture.occurrence_id,
      authority: "legacy", owner_epoch: capture.owner_epoch,
      sink: "state", target: "target", idempotency_key: "terminal",
      capability: "filesystem_write", created_at: capture.recorded_at
    )

    assert_raises(ArgumentError) { delivery.reconcile_intent!(valid) }
    foreign = Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol", occurrence_id: "occ-#{'f' * 64}", authority: "legacy",
      owner_epoch: capture.owner_epoch, sink: "state", target: "target",
      idempotency_key: "terminal", capability: "filesystem_write",
      created_at: capture.recorded_at
    )
    assert_raises(Hive::ConfigError) { delivery.reconcile_intent!(foreign) { {} } }
    result = delivery.reconcile_intent!(valid) do
      flunk("a terminal recovery receipt must not reconcile remotely")
    end

    assert_equal :committed, result.status
  end

  def test_sender_maps_known_not_delivered_errors_to_retry_safe_prepared
    store = DeliveryStore.new
    result = sender_with(store, ReceiptLedger.new).deliver_or_reconcile(
      intent,
      nil,
      -> { raise NotDelivered, "connection refused before send" }
    )

    assert_equal :retry_safe, result.status
    assert_equal(
      "connection refused before send",
      result.outcome.fetch("reason")
    )
    assert_includes store.calls.map(&:first), :reset
    assert_equal "prepared", store.state.fetch("state")
  end

  private

  def admission_with(lifecycle, module_execution:)
    Hive::Modules::Migration::EffectAdmission.new(
      module_name: "patrol",
      product_label: "patrol",
      config_key: "patrol",
      project_root: "/tmp/project",
      hive_state_path: "/tmp/project/.hive-state",
      capture: Data.define(:owner, :owner_epoch).new(
        owner: "legacy", owner_epoch: 7
      ),
      authority: "legacy",
      migration_lock: ->(&block) { block.call },
      ownership_loader: lambda do
        {
          "owner" => "legacy",
          "epoch" => 7,
          "admission" => true
        }
      end,
      config_loader: ->(_root) { { "patrol" => {} } },
      module_execution: module_execution,
      lifecycle_store_factory: ->(_root) { lifecycle }
    )
  end

  def sender_with(store, ledger, retry_safe: false)
    retry_policy = retry_safe.respond_to?(:call) ?
      retry_safe : ->(_intent) { retry_safe }
    Hive::Modules::Migration::EffectSender.new(
      product_label: "patrol",
      delivery_store: store,
      receipt_ledger: ledger,
      reconciliation_error: DeliveryError,
      pass_intent: false,
      not_delivered_error: NotDelivered,
      clock: -> { Time.utc(2026, 7, 28, 18) },
      retry_safe: retry_policy
    )
  end

  def intent
    Intent.new(
      occurrence_id: "occ-1",
      claim_generation: 1,
      capability: "github_pull_requests",
      sink: "pull_request",
      target: "owner/repo:branch",
      scope: {}
    )
  end

  def patrol_capture
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: {
        "kind" => "schedule",
        "id" => "timer-1",
        "schedule" => "continuous",
        "occurred_at" => Time.utc(2026, 7, 28, 18).iso8601(6)
      },
      reservation: { "kind" => "ordinary", "id" => "cycle-1" },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: {
        "kind" => "operation",
        "operation" => "effect-delivery-test"
      },
      selection:
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "patrol",
          rationale: "due"
        ),
      outcome_class: nil,
      outcome: nil,
      occurred_at: Time.utc(2026, 7, 28, 18),
      recorded_at: Time.utc(2026, 7, 28, 18)
    )
  end

  def capability_grants
    {
      "repository_write" => false,
      "github_mutations" => [],
      "external_commands" => [],
      "network_hosts" => [],
      "filesystem_read" => [],
      "filesystem_write" => [],
      "secrets" => []
    }
  end
end
