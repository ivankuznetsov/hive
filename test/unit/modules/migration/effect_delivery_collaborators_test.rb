require "test_helper"
require "hive/modules/migration/effect_admission"
require "hive/modules/migration/effect_delivery"
require "hive/modules/migration/effect_sender"

class ModulesMigrationEffectDeliveryCollaboratorsTest < Minitest::Test
  Claim = Data.define(:status, :token, :generation, :receipt)
  Intent = Data.define(
    :occurrence_id,
    :claim_generation,
    :capability,
    :sink,
    :target,
    :scope
  )
  Receipt = Data.define(:receipt_id)

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
    attr_accessor :claim, :state, :receipt
    attr_reader :calls

    def initialize
      @calls = []
    end

    def prepare_effect!(intent, **options)
      calls << [ :prepare, intent, options ]
    end

    def acquire_effect!(*, **)
      claim.is_a?(Array) ? claim.shift : claim
    end

    def mark_dispatch_uncertain!(intent, **options)
      calls << [ :fence, intent, options ]
    end

    def settle_effect_reconciled!(intent, **options)
      calls << [ :reconciled, intent, options ]
      { "state" => "reconciled" }
    end

    def resolve_effect_absent!(intent, **options)
      calls << [ :absent, intent, options ]
      { "state" => "known_not_sent" }
    end

    def settle_effect_claimed!(intent, **options)
      calls << [ :settled, intent, options ]
      { "state" => "committed" }
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

    def terminal_result(_intent)
      terminal
    end

    def replay_terminal(intent)
      calls << [ :replay, intent ]
      :terminal
    end

    def receipt_for_claim(_intent, claim)
      claim.receipt
    end

    def build(_intent, status, outcome)
      Receipt.new(
        receipt_id: "#{status}:#{outcome.hash}"
      )
    end

    def drain(intent)
      calls << [ :drain, intent ]
    end

    def terminal_result_from_state(_intent, state)
      state.fetch("state").to_sym
    end

    def known_not_sent(_intent, outcome, receipt)
      {
        status: :known_not_sent,
        outcome: outcome,
        receipt: receipt
      }
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

  def test_sender_reconcile_only_protocol_handles_every_claim_disposition
    store = DeliveryStore.new
    ledger = ReceiptLedger.new
    sender = sender_with(store, ledger)

    store.claim = Claim.new(
      status: :terminal,
      token: nil,
      generation: 1,
      receipt: "receipt-1"
    )
    assert_equal :terminal,
                 sender.reconcile_observed(intent, ->(*) { {} })

    store.claim = Claim.new(
      status: :busy,
      token: nil,
      generation: 1,
      receipt: "receipt-1"
    )
    error = assert_raises(DeliveryError) do
      sender.reconcile_observed(intent, ->(*) { {} })
    end
    assert_equal "active_sender_lease", error.reason

    store.claim = Claim.new(
      status: :acquired,
      token: "token",
      generation: 2,
      receipt: nil
    )
    result = sender.reconcile_observed(
      intent,
      ->(*) do
        {
          "status" => "absent",
          "outcome" => { "remote" => "absent" }
        }
      end
    )
    assert_equal :known_not_sent, result.fetch(:status)
    assert_includes store.calls.map(&:first), :fence

    store.claim = Claim.new(
      status: :reconcile,
      token: "token",
      generation: 3,
      receipt: nil
    )
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

    store.claim = Claim.new(
      status: :unknown,
      token: nil,
      generation: 4,
      receipt: nil
    )
    error = assert_raises(DeliveryError) do
      sender.reconcile_observed(intent, ->(*) { {} })
    end
    assert_match(/unrecognized/, error.reason)
  end

  def test_sender_delivery_fail_closed_paths_are_explicit
    store = DeliveryStore.new
    ledger = ReceiptLedger.new
    sender = sender_with(store, ledger)

    store.claim = Claim.new(
      status: :terminal,
      token: nil,
      generation: 1,
      receipt: "receipt-1"
    )
    assert_equal :terminal,
                 sender.deliver_or_reconcile(
                   intent, nil, -> { {} }
                 )

    store.claim = Claim.new(
      status: :unknown,
      token: nil,
      generation: 1,
      receipt: nil
    )
    assert_raises(DeliveryError) do
      sender.deliver_or_reconcile(intent, nil, -> { {} })
    end

    store.claim = Claim.new(
      status: :acquired,
      token: "token",
      generation: 2,
      receipt: nil
    )
    assert_raises(Hive::ConfigError) do
      sender.deliver_or_reconcile(intent, nil, -> { [] })
    end

    store.claim = Claim.new(
      status: :reconcile,
      token: "token",
      generation: 3,
      receipt: nil
    )
    ambiguous = assert_raises(DeliveryError) do
      sender.deliver_or_reconcile(
        intent, ->(*) { raise "remote unavailable" }, -> { {} }
      )
    end
    assert_equal "remote_identity_ambiguous", ambiguous.reason

    assert_raises(Hive::ConfigError) do
      sender_with(store, ledger, lease_sec: 0)
    end
    assert_raises(Hive::ConfigError) do
      sender_with(store, ledger, lease_sec: "bad")
    end
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

  def test_receipt_replay_and_sender_race_preserve_canonical_evidence
    store = DeliveryStore.new
    store.state = {
      "state" => "denied",
      "terminal_receipt_id" => "receipt-1",
      "outcome" => { "reason" => "revoked" }
    }
    store.receipt = Receipt.new(receipt_id: "receipt-1")
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

    claim = Claim.new(
      status: :busy,
      token: nil,
      generation: 2,
      receipt: "receipt-1"
    )
    assert_equal "receipt-1",
                 ledger.receipt_for_claim(intent, claim).receipt_id

    receipt_ledger = ReceiptLedger.new
    store.claim = [
      Claim.new(
        status: :reconcile,
        token: "token",
        generation: 1,
        receipt: nil
      ),
      Claim.new(
        status: :busy,
        token: nil,
        generation: 2,
        receipt: "receipt-1"
      )
    ]
    race = assert_raises(DeliveryError) do
      sender_with(store, receipt_ledger).deliver_or_reconcile(
        intent,
        ->(*) { { "status" => "absent", "outcome" => {} } },
        -> { {} }
      )
    end
    assert_equal "sender_lease_raced_after_reconciliation", race.reason

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

  def test_default_clock_terminal_replay_and_known_not_sent_are_durable
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
      config_loader: ->(*) { { "patrol" => {} } },
      claimant: "shadow"
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
      "outcome" => { "remote" => "present" }
    }
    store.receipt = Receipt.new(receipt_id: "receipt-1")
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
      config_loader: ->(*) { { "patrol" => {} } },
      claimant: "legacy"
    )
    result = delivery.reconcile!(
      sink: "state",
      target: "target",
      idempotency_key: "terminal",
      capability: "filesystem_write"
    ) { flunk("terminal replay must not reconcile remotely") }
    assert_equal :committed, result.status

    ledger = Hive::Modules::Migration::EffectReceiptLedger.new(
      delivery_store: store,
      evidence_store: evidence,
      denied_error: DeliveryError,
      clock: -> { Time.utc(2026, 7, 28, 18) }
    )
    built_intent = delivery.send(
      :build_intent,
      sink: "state",
      target: "target",
      idempotency_key: "known-absent",
      capability: "filesystem_write",
      claim_generation: nil,
      scope: {}
    )
    known_absent = ledger.known_not_sent(
      built_intent, { "remote" => "absent" }
    )
    assert_equal :known_not_sent, known_absent.status
    assert_equal "known_not_sent", known_absent.receipt.status
  end

  def test_sender_maps_known_not_delivered_errors_to_terminal_absence
    store = DeliveryStore.new
    store.claim = Claim.new(
      status: :acquired,
      token: "token",
      generation: 2,
      receipt: nil
    )
    result = sender_with(store, ReceiptLedger.new).deliver_or_reconcile(
      intent,
      nil,
      -> { raise NotDelivered, "connection refused before send" }
    )

    assert_equal :known_not_sent, result.fetch(:status)
    assert_equal(
      "connection refused before send",
      result.fetch(:outcome).fetch("reason")
    )
    assert_includes store.calls.map(&:first), :absent
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

  def sender_with(store, ledger, lease_sec: 30)
    Hive::Modules::Migration::EffectSender.new(
      product_label: "patrol",
      delivery_store: store,
      receipt_ledger: ledger,
      reconciliation_error: DeliveryError,
      pass_intent: false,
      not_delivered_error: NotDelivered,
      clock: -> { Time.utc(2026, 7, 28, 18) },
      lease_sec: lease_sec,
      claimant: "sender"
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
      trigger: { "kind" => "schedule", "id" => "timer-1" },
      reservation: { "kind" => "ordinary", "id" => "cycle-1" },
      owner: "legacy",
      owner_epoch: 1,
      decision_class: "due",
      decision: { "rationale" => "due" },
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
