require "test_helper"
require "hive/modules/migration/patrol_effect_index"

class ModulesMigrationPatrolEffectIndexTest < Minitest::Test
  NOW = Time.utc(2026, 8, 3, 12)

  def test_exact_replay_is_visible_but_does_not_increase_effect_count
    receipt = effect_receipt
    index = Hive::Modules::Migration::PatrolEffectIndex.build(
      receipts: [ receipt, receipt.to_h ]
    )

    assert index.frozen?
    assert_equal 1, index.effect_count
    assert_equal 1, index.replay_count
    assert_empty index.duplicate_effects
    assert_empty index.unsettled_effects
    assert index.valid?
  end

  def test_distinct_terminal_receipts_for_one_intent_are_duplicates
    committed = effect_receipt(status: "committed")
    reconciled = effect_receipt(status: "reconciled")
    index = Hive::Modules::Migration::PatrolEffectIndex.build(
      receipts: [ committed, reconciled ]
    )

    refute index.valid?
    assert_equal 1, index.effect_count
    assert index.duplicate_effects.any? { |value| value.start_with?("intent:") }
  end

  def test_semantic_duplicate_is_detected_across_restart_generations
    first = effect_receipt(owner_epoch: 1, idempotency_key: "finding:first")
    restarted = effect_receipt(
      owner_epoch: 2, idempotency_key: "finding:second"
    )
    index = Hive::Modules::Migration::PatrolEffectIndex.build(
      receipts: [ first, restarted ]
    )

    refute index.valid?
    assert_equal 1, index.effect_count
    assert index.duplicate_effects.any? { |value| value.start_with?("semantic:") }
  end

  def test_denied_shadow_attempts_are_observable_but_are_not_effects
    denied = effect_receipt(authority: "shadow", status: "denied")
    index = Hive::Modules::Migration::PatrolEffectIndex.build(
      receipts: [ denied ]
    )

    assert_equal 0, index.effect_count
    assert_equal [ denied.receipt_id ], index.observed_receipt_ids
    assert_empty index.duplicate_effects
    assert_empty index.unsettled_effects
    assert index.valid?
  end

  def test_unresolved_attempts_block_the_index_without_counting_as_effects
    attempted = effect_receipt(authority: "shadow", status: "attempted")
    unknown = effect_receipt(status: "unknown")
    index = Hive::Modules::Migration::PatrolEffectIndex.build(
      receipts: [ attempted, unknown ]
    )

    refute index.valid?
    assert_equal 0, index.effect_count
    assert_equal [ attempted.receipt_id, unknown.receipt_id ].sort,
                 index.unsettled_effects
  end

  def test_history_is_bounded
    receipt = effect_receipt
    with_constant(
      Hive::Modules::Migration::PatrolEffectIndex,
      :MAX_RECEIPTS,
      1
    ) do
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::PatrolEffectIndex.build(
          receipts: [ receipt, receipt ]
        )
      end
    end
  end

  def test_rejects_malformed_container_and_receipt_values
    [ nil, [ {} ] ].each do |receipts|
      error = assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::PatrolEffectIndex.build(receipts: receipts)
      end

      assert_equal "patrol effect index is malformed", error.message
    end
  end

  private

  def effect_receipt(owner_epoch: 1, idempotency_key: "finding:one",
                     authority: "legacy", status: "committed")
    intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol", occurrence_id: "occ-#{'a' * 64}",
      authority: authority, owner_epoch: owner_epoch, sink: "finding",
      target: "finding-1", idempotency_key: idempotency_key,
      capability: "finding_write", claim_generation: owner_epoch,
      scope: { "fingerprint" => "fingerprint-1" }, created_at: NOW
    )
    outcome = case status
    when "attempted"
      { "attempted" => true, "reason" => "shadow_effect_denied" }
    when "denied", "unknown"
      { "reason" => status }
    else
      { "finding_id" => "finding-1" }
    end
    Hive::Modules::Migration::EffectReceipt.build(
      intent: intent, status: status, outcome: outcome, recorded_at: NOW
    )
  end

  def with_constant(owner, name, replacement)
    original = owner.const_get(name, false)
    owner.send(:remove_const, name)
    owner.const_set(name, replacement)
    yield
  ensure
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, original)
  end
end
