require "test_helper"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/shadow_comparator"
require "hive/patrol/effect_gateway"
require "hive/patrol/state_store"

class PatrolEffectGatewayTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 12)

  def test_persists_intent_before_live_authorization_and_sink
    with_tmp_dir do |root|
      operations = []
      store, evidence = delivery(root, operations)
      gateway = gateway(
        root, store: store, evidence: evidence, operations: operations
      )

      result = perform(gateway, sink: "finding") do
        operations << :sink
        { "finding_id" => "finding-1" }
      end

      assert_equal :committed, result.status
      assert_operator operations.index(:intent), :<, operations.index(:lock)
      assert_operator operations.index(:capability_check), :<,
                      operations.index(:sink)
      assert_operator operations.index(:uncertain), :<,
                      operations.index(:sink)
      assert_operator operations.index(:sink), :<,
                      operations.index(:outcome)
      assert_operator operations.index(:outcome), :<,
                      operations.index(:evidence)
      assert_equal "committed", effect_state(store, sink: "finding")
        .fetch("state")
    end
  end

  def test_capability_revocation_denies_without_sink
    with_tmp_dir do |root|
      operations = []
      store, evidence = delivery(root, operations)
      gateway = gateway(
        root, store: store, evidence: evidence, operations: operations,
        capability_allowed: false
      )
      calls = 0

      error = assert_raises(Hive::Patrol::EffectGateway::Denied) do
        perform(gateway) { calls += 1 }
      end

      assert_equal "capability_revoked", error.reason
      assert_equal 0, calls
      assert_equal "denied", effect_state(store).fetch("state")
      assert_equal "denied", evidence.receipts.last.status
    end
  end

  def test_crashed_remote_dispatch_is_reconciliation_only
    with_tmp_dir do |root|
      operations = []
      store, evidence = delivery(root, operations)
      first = gateway(
        root, store: store, evidence: evidence, operations: operations
      )
      assert_raises(RuntimeError) do
        perform(first) { raise "crash at send boundary" }
      end
      calls = 0
      second = gateway(
        root, store: store, evidence: evidence, operations: operations,
        now: NOW + 2
      )

      error = assert_raises(
        Hive::Patrol::EffectGateway::ReconciliationRequired
      ) do
        perform(
          second,
          reconcile: ->(_intent) {
            { "status" => "ambiguous", "outcome" => {} }
          }
        ) { calls += 1 }
      end

      assert_equal "remote_identity_ambiguous", error.reason
      assert_equal 0, calls
      assert_equal "dispatch_uncertain", effect_state(store).fetch("state")
      assert_empty evidence.receipts
    end
  end

  def test_terminal_duplicate_reuses_canonical_receipt_without_redelivery
    with_tmp_dir do |root|
      operations = []
      store, evidence = delivery(root, operations)
      gateway = gateway(
        root, store: store, evidence: evidence, operations: operations
      )
      calls = 0

      first = perform(gateway) do
        calls += 1
        { "pr_url" => "https://github.com/owner/demo/pull/7" }
      end
      duplicate = perform(gateway) do
        calls += 1
        { "pr_url" => "https://github.com/owner/demo/pull/8" }
      end

      assert_equal 1, calls
      assert_equal first.receipt.to_h, duplicate.receipt.to_h
      assert_equal 1, evidence.receipts.size
    end
  end

  def test_persistence_boundary_redacts_closed_effect_outcomes
    with_tmp_dir do |root|
      operations = []
      store = Hive::Patrol::StateStore.new(root)
      store.reserve_occurrence!(capture, now: NOW)
      evidence = Hive::Modules::Migration::EvidenceStore.new(
        root: File.join(root, "evidence")
      )
      gateway = gateway(
        root, store: store, evidence: evidence, operations: operations
      )
      token = "github_pat_#{'a' * 24}"
      outcome = {
        "reason" => "validator emitted #{token}"
      }

      result = perform(gateway) { outcome }
      duplicate = perform(gateway) do
        flunk("terminal replay must not invoke the effect")
      end

      redacted = "[REDACTED:github_fine_grained_pat]"
      assert_equal "validator emitted #{redacted}",
                   result.outcome.fetch("reason")
      assert_equal result.receipt.to_h, duplicate.receipt.to_h
      assert_equal result.outcome,
                   effect_state(store).fetch("outcome")
      assert_equal result.outcome,
                   evidence.receipts.fetch(0).outcome

      comparison_root = File.join(root, "comparison")
      comparison = Hive::Modules::Migration::ShadowComparator.new(
        root: comparison_root,
        clock: -> { NOW }
      )
      comparison.record!(
        module_name: "patrol",
        trigger: capture.trigger,
        module_projection: capture.selection,
        configuration_digest: "c" * 64,
        occurred_at: NOW,
        legacy_capture: capture,
        legacy_effects: [ result.receipt ]
      )

      persisted = [
        Dir.glob(
          File.join(root, ".hive-state", "patrol", "occurrences", "*.json")
        ),
        Dir.glob(File.join(evidence.root, "receipts", "*.json")),
        Dir.glob(File.join(comparison_root, "patrol", "*.json"))
      ].flatten.map { |path| File.binread(path) }
      refute_empty persisted
      persisted.each do |bytes|
        refute_includes bytes, token
      end
    end
  end

  def test_reconcile_only_adopts_an_exact_existing_remote_effect
    with_tmp_dir do |root|
      operations = []
      store, evidence = delivery(root, operations)
      gateway = gateway(
        root, store: store, evidence: evidence, operations: operations
      )

      result = gateway.reconcile!(
        sink: "pull_request",
        target: "owner/demo:branch",
        idempotency_key: "finding-1:pull_request",
        capability: "github_pull_requests",
        scope: { "fingerprint" => "fingerprint-1" }
      ) do
        {
          "status" => "matched",
          "outcome" => {
            "pr_url" => "https://github.com/owner/demo/pull/7"
          }
        }
      end

      assert_equal :reconciled, result.status
      assert_equal result.receipt.to_h, evidence.receipts.first.to_h
      assert_equal "reconciled", effect_state(store).fetch("state")
      refute_includes operations, :sink
    end
  end

  def test_shadow_attempt_is_observational_only
    with_tmp_dir do |root|
      operations = []
      store = Hive::Patrol::StateStore.new(root)
      evidence = Evidence.new(operations)
      gateway = gateway(
        root, store: store, evidence: evidence, operations: operations,
        authority: "shadow"
      )

      error = assert_raises(Hive::Patrol::EffectGateway::Denied) do
        perform(gateway) { flunk "shadow must not reach the sink" }
      end

      assert_equal "shadow_mutation_forbidden", error.reason
      assert_nil store.occurrence(capture.occurrence_id)
      assert_equal [ "attempted" ], evidence.receipts.map(&:status)
    end
  end

  def test_stale_owner_epoch_is_denied
    with_tmp_dir do |root|
      operations = []
      store, evidence = delivery(root, operations)
      gateway = gateway(
        root, store: store, evidence: evidence, operations: operations,
        owner_epoch: 2
      )

      error = assert_raises(Hive::Patrol::EffectGateway::Denied) do
        perform(gateway, sink: "state") do
          flunk "stale epoch must not reach the sink"
        end
      end

      assert_equal "stale_owner_epoch", error.reason
    end
  end

  private

  class Evidence
    attr_reader :receipts

    def initialize(operations)
      @operations = operations
      @receipts = []
    end

    def append_receipt(receipt)
      @operations << :evidence
      existing = @receipts.find do |candidate|
        candidate.receipt_id == receipt.receipt_id
      end
      raise "receipt bytes conflict" if existing && existing.to_h != receipt.to_h

      @receipts << receipt unless existing
      receipt
    end
  end

  def delivery(root, operations)
    store = Hive::Patrol::StateStore.new(root)
    store.reserve_occurrence!(capture, now: NOW)
    instrumentation = Module.new
    instrumentation.define_method(:prepare_effect!) do |intent, **options|
      operations << :intent
      super(intent, **options)
    end
    instrumentation.define_method(:mark_dispatch_uncertain!) do |intent, **options|
      operations << :uncertain
      super(intent, **options)
    end
    instrumentation.define_method(:settle_effect!) do |intent, **options|
      operations << :outcome
      super(intent, **options)
    end
    store.singleton_class.prepend(instrumentation)
    [ store, Evidence.new(operations) ]
  end

  def gateway(root, store:, evidence:, operations:, authority: "legacy",
              capability_allowed: true, owner_epoch: 1, now: NOW)
    Hive::Patrol::EffectGateway.new(
      project_root: root,
      hive_state_path: File.join(root, ".hive-state"),
      capture: capture,
      authority: authority,
      evidence_store: evidence,
      delivery_store: store,
      migration_lock: lambda do |&block|
        operations << :lock
        block.call
      end,
      ownership_loader: lambda do
        operations << :migration_reload
        {
          "owner" => "legacy",
          "epoch" => owner_epoch,
          "admission" => true
        }
      end,
      config_loader: lambda do |_path|
        operations << :config_reload
        { "patrol" => { "enabled" => true } }
      end,
      capability_checker: lambda do |**|
        operations << :capability_check
        capability_allowed
      end,
      clock: -> { now }
    )
  end

  def perform(gateway, sink: "pull_request", reconcile: nil, &effect)
    gateway.perform!(
      sink: sink,
      target: sink == "state" ? "state" : "owner/demo:branch",
      idempotency_key: "finding-1:#{sink}",
      capability: sink == "state" ? "filesystem_write" :
        "github_pull_requests",
      scope: { "fingerprint" => "fingerprint-1" },
      reconcile: reconcile,
      &effect
    )
  end

  def effect_state(store, sink: "pull_request")
    intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol",
      occurrence_id: capture.occurrence_id,
      authority: "legacy",
      owner_epoch: 1,
      sink: sink,
      target: sink == "state" ? "state" : "owner/demo:branch",
      idempotency_key: "finding-1:#{sink}",
      capability: sink == "state" ? "filesystem_write" :
        "github_pull_requests",
      scope: { "fingerprint" => "fingerprint-1" },
      created_at: NOW
    )
    store.effect_state(intent)
  end

  def capture
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: {
        "kind" => "schedule",
        "id" => "schedule-1",
        "schedule" => "ordinary",
        "occurred_at" => NOW.iso8601(6)
      },
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: {
        "kind" => "operation",
        "operation" => "effect-gateway-test"
      },
      selection:
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "patrol",
          rationale: "due"
        ),
      outcome_class: nil,
      outcome: nil,
      occurred_at: NOW,
      recorded_at: NOW
    )
  end
end
