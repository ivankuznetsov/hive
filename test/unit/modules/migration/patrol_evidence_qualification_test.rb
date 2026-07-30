require "test_helper"
require "json_schemer"
require "hive/modules/migration/patrol_evidence_receipt"
require "hive/modules/migration/patrol_effect_index"
require "hive/modules/migration/patrol_evidence_verifier"
require "hive/modules/migration/shadow_comparator"
require_relative "../../../support/patrol_evidence_scenario"

class ModulesMigrationPatrolEvidenceQualificationTest < Minitest::Test
  include PatrolEvidenceScenario

  START = PatrolEvidenceScenario::START
  CONFIGURATION_DIGESTS =
    PatrolEvidenceScenario::CONFIGURATION_DIGESTS

  def test_qualification_core_has_explicit_receipt_index_and_verifier_boundaries
    assert Hive::Modules::Migration::PatrolEvidenceReceipt
    assert Hive::Modules::Migration::PatrolEffectIndex
    assert Hive::Modules::Migration::PatrolEvidenceVerifier
  end

  def test_receipt_is_canonical_bounded_and_identity_checked
    with_qualification do |records, decision_refs, effect_index, bindings|
      receipt = build_receipt(
        decision_refs: decision_refs,
        effect_index: effect_index,
        bindings: bindings
      )

      assert_match(/\Apatrol-evidence-[0-9a-f]{64}\z/, receipt.receipt_id)
      assert_equal receipt, Hive::Modules::Migration::PatrolEvidenceReceipt.from_h(
        receipt.to_h
      )
      schema = JSONSchemer.schema(
        Pathname(
          Hive::Schemas.schema_path("hive-patrol-evidence-receipt")
        )
      )
      assert_empty schema.validate(receipt.to_h).to_a

      Dir.mktmpdir("patrol-evidence-receipt") do |root|
        path = File.join(root, "receipt.json")
        receipt.write(path)
        assert_equal(
          Hive::WorkflowPackage::CanonicalJSON.generate(receipt.to_h),
          File.binread(path)
        )
        assert_equal receipt,
                     Hive::Modules::Migration::PatrolEvidenceReceipt.load(path)
      end

      tampered = Marshal.load(Marshal.dump(receipt.to_h))
      tampered["candidate"]["sha"] = "f" * 40
      error = assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::PatrolEvidenceReceipt.from_h(tampered)
      end
      assert_match(/identity does not match/, error.message)

      oversized = receipt.to_h.merge(
        "artifacts" => {
          "x" * (
            Hive::Modules::Migration::PatrolEvidenceReceipt::MAX_STRING_BYTES + 1
          ) => "f" * 64
        }
      )
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::PatrolEvidenceReceipt.from_h(oversized)
      end
    end
  end

  def test_effect_index_detects_run_wide_duplicates_and_denied_module_attempts
    with_qualification do |records, _decision_refs, effect_index, _bindings|
      assert_empty effect_index.duplicate_keys
      assert_equal records.length, effect_index.legacy_count
      assert_equal 0, effect_index.module_count

      duplicated = Hive::Modules::Migration::PatrolEffectIndex.build(
        records: records + [ records.first ]
      )
      assert_equal 1, duplicated.duplicate_keys.length

      module_record = record_for(
        module_name: "patrol",
        index: 99,
        decision_class: "due",
        module_effect: true
      )
      module_index = Hive::Modules::Migration::PatrolEffectIndex.build(
        records: [ module_record ]
      )
      assert_equal 1, module_index.module_count
      module_entry = module_index.entries.find do |entry|
        entry.fetch("channel") == "module"
      end
      assert_equal "denied", module_entry.fetch("status")
    end
  end

  def test_same_day_diverse_protocol_verifies_without_an_elapsed_time_gate
    with_qualification do |records, decision_refs, effect_index, bindings|
      receipt = build_receipt(
        decision_refs: decision_refs,
        effect_index: effect_index,
        bindings: bindings,
        observed_started_at: START,
        observed_ended_at: START + 30
      )
      result = Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: receipt,
        records: records,
        current_bindings: bindings
      )

      assert result.verified?
      assert_equal "verified", result.status
      assert_empty result.blockers
      assert_equal 30, receipt.to_h.dig("observed", "elapsed_seconds")
      assert_equal CONFIGURATION_DIGESTS, result.configuration_digests
      assert_equal effect_index.digest, result.effect_index.digest
    end
  end

  def test_verifier_fails_closed_for_stale_partial_mixed_and_forged_evidence
    with_qualification do |records, decision_refs, effect_index, bindings|
      receipt = build_receipt(
        decision_refs: decision_refs,
        effect_index: effect_index,
        bindings: bindings,
        observed_started_at: START - (365 * 24 * 60 * 60),
        observed_ended_at: START + 1
      )

      stale_bindings = Marshal.load(Marshal.dump(bindings))
      stale_bindings["candidate"]["sha"] = "f" * 40
      stale = Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: receipt,
        records: records,
        current_bindings: stale_bindings
      )
      assert_includes stale.blockers, "candidate_binding_mismatch"

      partial_bindings = Marshal.load(Marshal.dump(bindings))
      partial_bindings["required_matrix"] << "missing_protocol_case"
      partial = Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: receipt,
        records: records,
        current_bindings: partial_bindings
      )
      assert_includes partial.blockers, "scenario_matrix_mismatch"

      mixed = Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: receipt,
        records: records.drop(1),
        current_bindings: bindings
      )
      assert_includes mixed.blockers, "decision_set_mismatch"

      repeated = records.select { |record| record["module"] == "patrol" }
                        .first(1)
                        .then { |record| Array.new(10, record.first) }
      forged = Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: receipt,
        records: repeated,
        current_bindings: bindings
      )
      assert_includes forged.blockers, "decision_set_mismatch"
      assert_includes forged.blockers, "patrol:unique_decisions_below_10"
      refute forged.verified?
    end
  end

  def test_blocked_and_failed_lanes_never_verify
    with_qualification do |records, decision_refs, effect_index, bindings|
      %w[blocked failed].each do |lane_result|
        receipt = build_receipt(
          decision_refs: decision_refs,
          effect_index: effect_index,
          bindings: bindings,
          lane_result: lane_result,
          failure_reason: "provider_unavailable"
        )
        result = Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
          receipt: receipt,
          records: records,
          current_bindings: bindings
        )
        assert_equal lane_result, result.status
        assert_includes result.blockers, "lane_#{lane_result}:provider_unavailable"
        refute result.verified?
      end
    end
  end
end
