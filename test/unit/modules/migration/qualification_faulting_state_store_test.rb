require "test_helper"
require "hive/modules/migration/qualification_faulting_state_store"

class QualificationFaultingStateStoreTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 31, 12)
  CheckpointReached = Class.new(StandardError)

  def test_checkpoints_after_effect_intent_is_durable
    with_tmp_dir do |root|
      intent = effect_intent
      calls = []
      store = faulting_store(root) do |phase, payload|
        durable = Hive::Patrol::StateStore.new(root).effect_state(intent)
        calls << [ phase, payload, durable ]
      end
      store.reserve_occurrence!(capture, now: NOW)

      result = store.prepare_effect!(intent, now: NOW)

      phase, payload, durable = calls.fetch(0)
      assert_equal(
        Hive::Modules::Migration::QualificationFaultingStateStore::
          AFTER_EFFECT_INTENT,
        phase
      )
      assert_equal intent.intent_id,
                   payload.dig("identity", "intent_id")
      assert_equal result, payload.fetch("result")
      assert_equal "prepared", durable.fetch("state")
      assert payload.frozen?
    end
  end

  def test_checkpoints_immediately_before_effect_settlement
    with_tmp_dir do |root|
      intent = effect_intent
      calls = []
      store = faulting_store(root) do |phase, payload|
        durable = Hive::Patrol::StateStore.new(root).effect_state(intent)
        calls << [ phase, payload, durable ]
      end
      store.reserve_occurrence!(capture, now: NOW)
      store.prepare_effect!(intent, now: NOW)
      store.mark_dispatch_uncertain!(intent, now: NOW)
      calls.clear
      outcome = { "content_digest" => "a" * 64 }

      receipt = store.settle_effect!(
        intent,
        status: "committed",
        outcome: outcome,
        now: NOW + 1
      )

      phase, payload, durable = calls.fetch(0)
      assert_equal(
        Hive::Modules::Migration::QualificationFaultingStateStore::
          BEFORE_EFFECT_SETTLEMENT,
        phase
      )
      assert_equal "dispatch_uncertain", durable.fetch("state")
      assert_equal(
        "dispatch_uncertain",
        payload.dig("result", "effect_state", "state")
      )
      assert_equal outcome, payload.dig("result", "outcome")
      assert_equal "committed", receipt.status
      assert_equal "committed", store.effect_state(intent).fetch("state")
    end
  end

  def test_checkpoints_while_reconciliation_result_is_held
    with_tmp_dir do |root|
      interrupt = false
      calls = []
      store = faulting_store(root) do |phase, payload|
        calls << [ phase, payload ]
        raise CheckpointReached if interrupt
      end
      store.send(
        :raw_write_fingerprints,
        "fingerprint-1" => { "state" => "open" }
      )
      arguments = {
        set: { "state" => "open" },
        deleted: [],
        replace: false
      }

      result = store.send(
        :reconcile_fingerprint_mapping,
        "fingerprint-1",
        **arguments
      )

      phase, payload = calls.fetch(0)
      assert_equal(
        Hive::Modules::Migration::QualificationFaultingStateStore::
          DURING_RECONCILIATION,
        phase
      )
      assert_equal "fingerprint-1",
                   payload.dig("identity", "fingerprint")
      assert_equal result, payload.fetch("result")

      interrupt = true
      assert_raises(CheckpointReached) do
        store.send(
          :reconcile_fingerprint_mapping,
          "fingerprint-1",
          **arguments
        )
      end
    end
  end

  def test_nil_checkpoint_matches_real_state_store_behavior
    with_tmp_dir do |root|
      expected = exercise_effect_lifecycle(
        Hive::Patrol::StateStore.new(File.join(root, "expected"))
      )
      actual = exercise_effect_lifecycle(
        faulting_store(File.join(root, "actual"))
      )

      assert_equal expected, actual
    end
  end

  private

  def faulting_store(root, &checkpoint)
    Hive::Modules::Migration::QualificationFaultingStateStore.new(
      root,
      checkpoint: checkpoint
    )
  end

  def exercise_effect_lifecycle(store)
    intent = effect_intent
    store.reserve_occurrence!(capture, now: NOW)
    prepared = store.prepare_effect!(intent, now: NOW)
    uncertain = store.mark_dispatch_uncertain!(intent, now: NOW)
    receipt = store.settle_effect!(
      intent,
      status: "committed",
      outcome: { "content_digest" => "a" * 64 },
      now: NOW + 1
    )
    store.send(
      :raw_write_fingerprints,
      "fingerprint-1" => { "state" => "open" }
    )
    reconciliation = store.send(
      :reconcile_fingerprint_mapping,
      "fingerprint-1",
      set: { "state" => "open" },
      deleted: []
    )
    [
      prepared,
      uncertain,
      receipt.to_h,
      store.effect_state(intent),
      reconciliation
    ]
  end

  def effect_intent
    Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol",
      occurrence_id: capture.occurrence_id,
      authority: "legacy",
      owner_epoch: 1,
      sink: "state",
      target: "fingerprints",
      idempotency_key: "qualification:fingerprints",
      capability: "filesystem_write",
      scope: { "fingerprint" => "fingerprint-1" },
      created_at: NOW
    )
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
      reservation: {
        "kind" => "ordinary",
        "id" => "reservation-1"
      },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: {
        "kind" => "operation",
        "operation" =>
          "qualification-faulting-state-store-test"
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
