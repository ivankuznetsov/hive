require "test_helper"
require "json"
require "json_schemer"
require "pathname"
require "hive/modules/migration/patrol_evidence_receipt"

class ModulesMigrationPatrolEvidenceReceiptTest < Minitest::Test
  NOW = Time.utc(2026, 8, 3, 12)

  def test_builds_a_canonical_deeply_immutable_receipt_from_u2_values
    attributes = receipt_attributes
    receipt = Hive::Modules::Migration::PatrolEvidenceReceipt.build(
      **attributes
    )

    attributes.fetch(:fault_steps) << "changed"
    attributes.fetch(:artifacts).first["kind"] = "changed"

    assert receipt.frozen?
    assert receipt.capture.frozen?
    assert receipt.effects.frozen?
    assert receipt.artifacts.frozen?
    assert receipt.artifacts.first.frozen?
    assert_equal [ "restart_after_decision" ], receipt.fault_steps
    assert_equal "comparison", receipt.artifacts.first.fetch("kind")
    assert_match(/\Aevidence-[0-9a-f]{64}\z/, receipt.receipt_id)
    assert_equal receipt.to_h,
                 Hive::Modules::Migration::PatrolEvidenceReceipt.from_h(
                   receipt.to_h
                 ).to_h

    schema = JSONSchemer.schema(Pathname(
      Hive::Schemas.schema_path("hive-patrol-evidence-receipt", version: 1)
    ))
    assert_empty schema.validate(receipt.to_h).to_a
  end

  def test_normalizes_set_like_evidence_before_computing_identity
    first = Hive::Modules::Migration::PatrolEvidenceReceipt.build(
      **receipt_attributes(
        fault_steps: %w[restart_after_effect restart_after_decision],
        artifacts: [
          { "kind" => "trace", "digest" => "9" * 64 },
          { "kind" => "comparison", "digest" => "8" * 64 }
        ]
      )
    )
    second = Hive::Modules::Migration::PatrolEvidenceReceipt.build(
      **receipt_attributes(
        fault_steps: %w[restart_after_decision restart_after_effect],
        artifacts: [
          { "kind" => "comparison", "digest" => "8" * 64 },
          { "kind" => "trace", "digest" => "9" * 64 }
        ]
      )
    )

    assert_equal first.receipt_id, second.receipt_id
    assert_equal first.to_h, second.to_h
  end

  def test_rejects_forgery_duplicates_and_cross_occurrence_effects
    receipt = Hive::Modules::Migration::PatrolEvidenceReceipt.build(
      **receipt_attributes
    )
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceReceipt.from_h(
        receipt.to_h.merge("receipt_id" => "evidence-#{'f' * 64}")
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceReceipt.build(
        **receipt_attributes(fault_steps: %w[restart restart])
      )
    end

    other = effect_receipt(occurrence_id: "occ-#{'e' * 64}")
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceReceipt.build(
        **receipt_attributes(effects: [ other ])
      )
    end
  end

  def test_requires_terminal_legacy_capture_matching_projection_and_review_time
    provisional = capture(outcome_class: nil, outcome: nil)
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceReceipt.build(
        **receipt_attributes(capture: provisional)
      )
    end
    mismatched = Hive::Modules::Migration::PatrolDecisionProjection.build(
      module_name: "patrol", rationale: "not_due"
    )
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceReceipt.build(
        **receipt_attributes(module_projection: mismatched)
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceReceipt.build(
        **receipt_attributes(generated_at: NOW + 10, reviewed_at: NOW)
      )
    end
  end

  def test_rejects_unknown_keys_and_oversized_values
    receipt = Hive::Modules::Migration::PatrolEvidenceReceipt.build(
      **receipt_attributes
    )
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceReceipt.from_h(
        receipt.to_h.merge("unexpected" => true)
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceReceipt.build(
        **receipt_attributes(run_id: "x" * 257)
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceReceipt.build(
        **receipt_attributes(fault_steps: nil)
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceReceipt.build(
        **receipt_attributes(reviewer: "x" * 1_025)
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceReceipt.build(
        **receipt_attributes(capture: capture(repository: "owner/foreign"))
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolEvidenceReceipt.from_h(
        receipt.to_h.merge("generated_at" => NOW.iso8601)
      )
    end
    %i[effects fault_steps artifacts].each do |key|
      oversized = Array.new(
        Hive::Modules::Migration::PatrolEvidenceReceipt::MAX_ITEMS + 1,
        key == :fault_steps ? "step" : {}
      )
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::PatrolEvidenceReceipt.build(
          **receipt_attributes(key => oversized)
        )
      end
    end
  end

  def test_rejects_wrong_typed_and_invalid_utf8_string_fields
    mutations = [
      { run_id: 1 },
      { candidate_sha: Integer("1" * 40) },
      { fault_steps: [ 1 ] },
      { artifacts: [ { "kind" => 1, "digest" => "8" * 64 } ] },
      {
        artifacts: [
          { "kind" => "comparison", "digest" => Integer("8" * 64) }
        ]
      },
      { reviewer: 1 },
      { reviewer: "\xFF".b }
    ]

    mutations.each do |mutation|
      assert_raises(Hive::ConfigError, mutation.inspect) do
        Hive::Modules::Migration::PatrolEvidenceReceipt.build(
          **receipt_attributes(mutation)
        )
      end
    end
  end

  private

  def receipt_attributes(overrides = {})
    value = {
      run_id: "run-1", candidate_sha: "1" * 40,
      catalog_digest: "2" * 64, source_digest: "3" * 64,
      manifest_digest: "4" * 64, configuration_digest: "5" * 64,
      scenario_manifest_digest: "6" * 64,
      repository: {
        "id" => "owner/demo", "sha" => "7" * 40,
        "change_window" => "window-1"
      },
      capture: capture,
      module_projection: projection,
      decision_class: "positive_finding",
      effects: [],
      fault_steps: [ "restart_after_decision" ],
      artifacts: [
        { "kind" => "comparison", "digest" => "8" * 64 }
      ],
      reviewer: "reviewer-1", generated_at: NOW, reviewed_at: NOW + 1
    }
    value.merge(overrides)
  end

  def projection
    Hive::Modules::Migration::PatrolDecisionProjection.build(
      module_name: "patrol", rationale: "due"
    )
  end

  def capture(outcome_class: "completed",
              outcome: { "rationale" => "completed", "finding_ids" => [] },
              repository: "owner/demo")
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1", "name" => "demo",
        "repository" => repository
      },
      trigger: { "kind" => "manual", "id" => "manual-1" },
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: "legacy", owner_epoch: 1,
      selection_input: { "kind" => "operation", "operation" => "test" },
      selection: projection, outcome_class: outcome_class, outcome: outcome,
      occurred_at: NOW, recorded_at: NOW
    )
  end

  def effect_receipt(occurrence_id: capture.occurrence_id)
    intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol", occurrence_id: occurrence_id,
      authority: "legacy", owner_epoch: 1, sink: "finding",
      target: "finding-1", idempotency_key: "finding-1",
      capability: "finding_write", created_at: NOW
    )
    Hive::Modules::Migration::EffectReceipt.build(
      intent: intent, status: "committed",
      outcome: { "finding_id" => "finding-1" }, recorded_at: NOW
    )
  end
end
