require "test_helper"
require "json_schemer"
require "hive/modules/migration/patrol_evidence_receipt"
require "hive/modules/migration/patrol_effect_index"
require "hive/modules/migration/patrol_evidence_verifier"
require "hive/modules/migration/shadow_comparator"

class ModulesMigrationPatrolEvidenceQualificationTest < Minitest::Test
  START = Time.utc(2026, 7, 30, 9, 0, 0)
  CANDIDATE_SHA = "c" * 40
  DIGESTS = {
    "catalog_digest" => "a" * 64,
    "source_digest" => "b" * 64,
    "manifest_digest" => "c" * 64,
    "installed_digest" => nil
  }.freeze
  CONFIGURATION_DIGESTS = {
    "patrol" => "d" * 64,
    "architecture-patrol" => "e" * 64
  }.freeze

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

  private

  def with_qualification
    records = qualification_records
    effect_index = Hive::Modules::Migration::PatrolEffectIndex.build(
      records: records
    )
    decision_refs = records.each_with_index.map do |record, index|
      decision_class = decision_classes.fetch(record.fetch("module")).fetch(
        index_for_module(records, record, index)
      )
      {
        "decision_id" => record.fetch("decision_id"),
        "module" => record.fetch("module"),
        "decision_class" => decision_class,
        "repository" => "owner/evidence",
        "repository_sha" => index.even? ? "1" * 40 : "2" * 40,
        "trigger_digest" => record.fetch("trigger_digest"),
        "record_digest" => record.fetch("semantic_digest"),
        "control" => control_for(decision_class)
      }
    end
    bindings = current_bindings(
      decision_refs: decision_refs,
      expected_legacy_effect_keys: effect_index.legacy_keys
    )
    yield records, decision_refs, effect_index, bindings
  end

  def qualification_records
    decision_classes.flat_map do |module_name, classes|
      classes.each_with_index.map do |decision_class, index|
        record_for(
          module_name: module_name,
          index: index,
          decision_class: decision_class
        )
      end
    end
  end

  def decision_classes
    {
      "patrol" => %w[
        ordinary_positive_finding clean_negative due not_due new_commit
        same_commit capacity_deferral quota_deferral cooldown_retry
        timer_reset_reload
      ],
      "architecture-patrol" => %w[
        architecture_positive_thesis clean_negative due not_due new_commit
        same_commit restart concurrent_duplicate_delivery partial_failure
        launch_failure reconciliation_failure
      ]
    }
  end

  def index_for_module(records, record, index)
    records.first(index).count do |candidate|
      candidate["module"] == record["module"]
    end
  end

  def record_for(module_name:, index:, decision_class:, module_effect: false)
    trigger = { "kind" => "manual", "id" => "#{module_name}-#{index}" }
    rationale = %w[
      clean_negative not_due capacity_deferral quota_deferral cooldown_retry
    ].include?(decision_class) ? "not_due" : "due"
    projection = projection_for(module_name, trigger, rationale)
    capture = capture_for(
      module_name, trigger, projection, decision_class: decision_class
    )
    legacy_receipt = effect_receipt(
      capture,
      "#{module_name}-#{index}",
      authority: "legacy",
      status: "committed"
    )
    module_receipts = if module_effect
      [
        effect_receipt(
          capture,
          "#{module_name}-#{index}-shadow",
          authority: "shadow",
          status: "denied"
        )
      ]
    else
      []
    end
    Dir.mktmpdir("patrol-evidence-record") do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(
        root: root,
        clock: -> { START + index }
      )
      comparator.record!(
        module_name: module_name,
        trigger: trigger,
        legacy_capture: capture,
        module_projection: projection,
        configuration_digest: CONFIGURATION_DIGESTS.fetch(module_name),
        occurred_at: START + index,
        legacy_effects: [ legacy_receipt ],
        module_effects: module_receipts
      )
    end
  end

  def projection_for(module_name, trigger, rationale)
    attributes = {
      module_name: module_name,
      rationale: rationale
    }
    if module_name == "architecture-patrol" && rationale == "due"
      attributes[:job_id] = trigger.fetch("id")
      attributes[:phase] = "discovery"
    end
    Hive::Modules::Migration::PatrolDecisionProjection.build(**attributes)
  end

  def capture_for(module_name, trigger, projection, decision_class:)
    architecture = module_name == "architecture-patrol"
    positive = %w[
      ordinary_positive_finding architecture_positive_thesis
    ].include?(decision_class)
    outcome = if architecture
      {
        "rationale" => projection.rationale,
        "action_count" => positive ? 1 : 0,
        "job_id" => projection.job_id,
        "complete" => true
      }
    else
      {
        "rationale" => projection.rationale,
        "findings" => positive ? 1 : 0,
        "finding_ids" => positive ? [ "finding-#{trigger.fetch('id')}" ] : [],
        "ok" => true
      }
    end
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: module_name,
      project: {
        "project_id" => "project-evidence",
        "name" => "evidence",
        "repository" => "owner/evidence"
      },
      trigger: trigger,
      reservation:
        architecture ?
          {
            "kind" => "architecture",
            "id" => trigger.fetch("id"),
            "job_id" => trigger.fetch("id")
          } :
          { "kind" => "ordinary", "id" => trigger.fetch("id") },
      owner: "legacy",
      owner_epoch: 1,
      selection_input:
        architecture ?
          {
            "kind" => "candidate",
            "job_id" => trigger.fetch("id"),
            "phase" => "discovery"
          } :
          { "kind" => "operation", "operation" => "compressed-evidence" },
      selection: projection,
      outcome_class: "completed",
      outcome: outcome,
      occurred_at: START,
      recorded_at: START
    )
  end

  def effect_receipt(capture, suffix, authority:, status:)
    intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: capture.module_name,
      occurrence_id: capture.occurrence_id,
      authority: authority,
      owner_epoch: capture.owner_epoch,
      sink: "state",
      target: "state/#{suffix}",
      idempotency_key: "effect/#{suffix}",
      capability: "filesystem_write",
      created_at: START
    )
    Hive::Modules::Migration::EffectReceipt.build(
      intent: intent,
      status: status,
      outcome:
        status == "denied" ?
          { "attempted" => true, "reason" => "shadow_only" } :
          { "transition_status" => "applied" },
      recorded_at: START
    )
  end

  def control_for(decision_class)
    return decision_class if %w[
      ordinary_positive_finding architecture_positive_thesis clean_negative
    ].include?(decision_class)

    "none"
  end

  def current_bindings(decision_refs:, expected_legacy_effect_keys:)
    {
      "run_id" => "compressed-run-1",
      "lane" => "deterministic",
      "candidate" => DIGESTS.merge("sha" => CANDIDATE_SHA),
      "configuration_digests" => CONFIGURATION_DIGESTS,
      "scenario_manifest_digest" => "f" * 64,
      "artifact_digests" => {
        "bounded_log" => "1" * 64,
        "scenario_manifest" => "2" * 64
      },
      "decision_expectations" => decision_refs.map do |row|
        row.reject { |key, _value| key == "record_digest" }
      end,
      "required_matrix" =>
        Hive::Modules::Migration::PatrolEvidenceVerifier::REQUIRED_MATRIX,
      "expected_legacy_effect_keys" => expected_legacy_effect_keys
    }
  end

  def build_receipt(decision_refs:, effect_index:, bindings:,
                    lane_result: "passed", failure_reason: nil,
                    observed_started_at: START,
                    observed_ended_at: START + 30)
    Hive::Modules::Migration::PatrolEvidenceReceipt.build(
      run_id: bindings.fetch("run_id"),
      lane: bindings.fetch("lane"),
      lane_result: lane_result,
      failure_reason: failure_reason,
      candidate: bindings.fetch("candidate"),
      configuration_digests: bindings.fetch("configuration_digests"),
      scenario_manifest_digest:
        bindings.fetch("scenario_manifest_digest"),
      decision_refs: decision_refs,
      matrix: bindings.fetch("required_matrix"),
      faults: Hive::Modules::Migration::PatrolEvidenceVerifier::REQUIRED_FAULTS,
      restart_count: 2,
      effect_index_digest: effect_index.digest,
      expected_legacy_effect_keys:
        bindings.fetch("expected_legacy_effect_keys"),
      artifact_digests: bindings.fetch("artifact_digests"),
      reviewer: "operator",
      generated_at: START + 31,
      reviewed_at: START + 31,
      observed_started_at: observed_started_at,
      observed_ended_at: observed_ended_at
    )
  end
end
