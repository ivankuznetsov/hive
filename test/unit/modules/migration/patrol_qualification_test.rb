require "test_helper"
require "digest"
require "json"
require "hive/modules/migration/patrol_qualification"
require "hive/modules/migration/patrols"
require "hive/modules/migration/report"
require "hive/modules/migration/report_projection"

class ModulesMigrationPatrolQualificationTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 3, 12)

  def test_completeness_and_diversity_qualify_without_an_elapsed_gate
    receipts = complete_receipts(spacing: 1)
    qualification = build_qualification(receipts)

    assert qualification.frozen?
    assert qualification.qualified?
    assert_equal "qualified", qualification.status
    assert_operator qualification.elapsed_seconds, :<, 60
    assert_equal 10,
                 qualification.modules.dig("patrol", "decision_count")
    assert_equal 10,
                 qualification.modules.dig(
                   "patrol", "decision_identities"
                 ).size
    assert_equal 2,
                 qualification.modules.dig("patrol", "decision_classes").size
    assert_equal 2,
                 qualification.modules.dig("patrol", "repository_shas").size
    assert_equal 2,
                 qualification.modules.dig("patrol", "change_windows").size
    assert_empty qualification.blockers
  end

  def test_public_admission_verifies_documents_and_cas_merges_report
    with_tmp_dir do |root|
      state_root = File.join(root, ".hive-state")
      path = Hive::Modules::Migration::Patrols.report_file(
        root, hive_state_path: state_root
      )
      current = Hive::Modules::Migration::ReportProjection.build(
        qualifications: [], generated_at: NOW,
        migration: {
          "source_schema_version" => 1,
          "source_digest" => "b" * 64,
          "archive_digest" => "b" * 64,
          "disposition" => "evidence_required"
        }
      )
      Hive::Modules::Migration::Report.write_projection(path, current)
      expected_digest = Digest::SHA256.hexdigest(File.binread(path))
      verified = complete_receipts
      documents = verified.map { |value| value.receipt.to_h }
      bindings = verified.map { |value| expected_bindings(value.receipt) }

      wrong = bindings.dup
      wrong[0] = wrong.fetch(0).merge("trigger_id" => "wrong-trigger")
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Patrols.admit_deterministic_qualification!(
          root, receipts: documents, expected_bindings: wrong,
          generated_at: NOW + 30,
          expected_report_digest: expected_digest,
          hive_state_path: state_root
        )
      end
      assert_equal expected_digest,
                   Digest::SHA256.hexdigest(File.binread(path))

      report =
        Hive::Modules::Migration::Patrols.admit_deterministic_qualification!(
          root, receipts: documents, expected_bindings: bindings,
          generated_at: NOW + 30,
          expected_report_digest: expected_digest,
          hive_state_path: state_root
        )

      assert_equal "qualified",
                   report.lanes.fetch("deterministic").status
      assert_equal report.to_h,
                   Hive::Modules::Migration::Report.load(path).to_h
    end
  end

  def test_timestamp_spread_cannot_replace_decision_or_repository_diversity
    receipts = %w[patrol architecture-patrol].flat_map do |module_name|
      10.times.map do |index|
        verified_receipt(
          module_name: module_name, index: index,
          decision_class: "same_class", repository_sha: "7" * 40,
          occurred_at: NOW + (index * 24 * 60 * 60)
        )
      end
    end
    qualification = build_qualification(receipts)

    refute qualification.qualified?
    assert_equal "evidence_required", qualification.status
    assert_includes qualification.blockers,
                    "patrol:decision_class_diversity_below_2"
    assert_includes qualification.blockers,
                    "patrol:repository_diversity_below_2"
    assert_operator qualification.elapsed_seconds, :>=, 7 * 24 * 60 * 60
  end

  def test_repeated_comparable_identities_cannot_inflate_decision_count
    receipts = %w[patrol architecture-patrol].flat_map do |module_name|
      10.times.map do |index|
        control = index % 2
        verified_receipt(
          module_name: module_name, index: index,
          decision_index: control,
          trigger_id: "control-#{control}",
          decision_class: control.zero? ? "positive" : "negative",
          repository_sha: (control.zero? ? "7" : "8") * 40,
          change_window: "window-#{control}",
          occurred_at: NOW + index
        )
      end
    end

    qualification = build_qualification(receipts)

    refute qualification.qualified?
    assert_equal 2,
                 qualification.modules.dig("patrol", "decision_count")
    assert_includes qualification.blockers,
                    "patrol:decision_count_below_10"
  end

  def test_mixed_runs_fail_closed_and_configuration_drift_blocks
    receipts = complete_receipts
    foreign = verified_receipt(
      module_name: "patrol", index: 99, run_id: "run-2"
    )
    assert_raises(Hive::ConfigError) do
      build_qualification(receipts + [ foreign ])
    end
    foreign_repository = receipts.dup
    foreign_repository[0] = verified_receipt(
      module_name: "patrol", index: 0,
      repository_id: "owner/foreign"
    )
    assert_raises(Hive::ConfigError) do
      build_qualification(foreign_repository)
    end

    changed = receipts.dup
    changed[0] = verified_receipt(
      module_name: "patrol", index: 0,
      configuration_digest: "e" * 64
    )
    qualification = build_qualification(changed)
    assert_equal "evidence_required", qualification.status
    assert_includes qualification.blockers,
                    "patrol:configuration_changed"
  end

  def test_duplicate_terminal_effects_block_readiness_across_records
    first = verified_receipt(
      module_name: "patrol", index: 0, effect_status: "committed"
    )
    second = verified_receipt(
      module_name: "patrol", index: 0, effect_status: "reconciled"
    )
    receipts = complete_receipts.reject do |value|
      value.capture.module_name == "patrol" &&
        %w[manual-patrol-0 manual-patrol-1].include?(
          value.capture.trigger.fetch("id")
        )
    end + [ first, second ]
    index = Hive::Modules::Migration::PatrolEffectIndex.build(
      receipts: receipts.flat_map(&:effects)
    )
    qualification = Hive::Modules::Migration::PatrolQualification.build(
      lane: "deterministic", verified_receipts: receipts,
      effect_index: index, generated_at: NOW + 30
    )

    assert_equal "evidence_required", qualification.status
    assert_includes qualification.blockers, "duplicate_effects"
    refute_empty qualification.duplicate_effects
  end

  def test_exact_replay_stays_visible_without_increasing_readiness
    effectful = verified_receipt(
      module_name: "patrol", index: 0, effect_status: "committed"
    )
    receipts = complete_receipts.reject do |value|
      value.capture.trigger.fetch("id") == "manual-patrol-0"
    end + [ effectful ]
    replayed = receipts + [ effectful ]
    qualification = build_qualification(replayed)

    assert qualification.qualified?
    assert_equal 1, qualification.decision_replay_count
    assert_equal 1, qualification.effect_replay_count
    assert_equal 1, qualification.effect_count
    assert_equal 10,
                 qualification.modules.dig("patrol", "decision_count")
  end

  def test_unsettled_effects_and_capture_wrapper_substitution_fail_closed
    unsettled = verified_receipt(
      module_name: "patrol", index: 0, effect_status: "unknown"
    )
    receipts = complete_receipts.reject do |value|
      value.capture.trigger.fetch("id") == "manual-patrol-0"
    end + [ unsettled ]
    qualification = build_qualification(receipts)

    assert_equal "evidence_required", qualification.status
    assert_includes qualification.blockers, "unsettled_effects"
    assert_equal unsettled.effects.map(&:receipt_id),
                 qualification.unsettled_effects

    first = verified_receipt(
      module_name: "patrol", index: 77,
      repository_sha: "7" * 40, change_window: "window-0"
    )
    substituted = verified_receipt(
      module_name: "patrol", index: 77,
      repository_sha: "8" * 40, change_window: "window-1"
    )
    assert_equal first.capture.capture_id, substituted.capture.capture_id
    assert_raises(Hive::ConfigError) do
      build_qualification([ first, substituted ])
    end
  end

  def test_later_contradiction_creates_typed_invalidation
    prior = build_qualification(complete_receipts)
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolQualification.build(
        lane: "deterministic", verified_receipts: complete_receipts,
        effect_index: Hive::Modules::Migration::PatrolEffectIndex.build(
          receipts: []
        ),
        generated_at: NOW + 121,
        supersedes: prior.qualification_id,
        contradiction: {
          "kind" => "production_decision_diverged",
          "receipt_id" => "evidence-#{'f' * 64}",
          "observed_at" => (NOW + 120).iso8601(6)
        }
      )
    end
    contradiction = {
      "kind" => "production_decision_diverged",
      "receipt_id" => prior.receipt_ids.first,
      "observed_at" => (NOW + 120).iso8601(6)
    }
    invalidated = Hive::Modules::Migration::PatrolQualification.build(
      lane: "deterministic", verified_receipts: complete_receipts,
      effect_index: Hive::Modules::Migration::PatrolEffectIndex.build(
        receipts: []
      ),
      generated_at: NOW + 121,
      supersedes: prior.qualification_id,
      contradiction: contradiction
    )

    assert_equal "invalidated", invalidated.status
    assert_equal prior.qualification_id, invalidated.supersedes
    assert_equal contradiction, invalidated.contradiction
    assert_includes invalidated.blockers, "contradictory_telemetry"
  end

  def test_round_trip_recomputes_identity_and_rejects_extra_fields
    qualification = build_qualification(complete_receipts)
    assert_equal qualification.to_h,
                 Hive::Modules::Migration::PatrolQualification.from_h(
                   qualification.to_h
                 ).to_h
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolQualification.from_h(
        qualification.to_h.merge("unexpected" => true)
      )
    end
    forged = JSON.parse(JSON.generate(qualification.to_h))
    forged.fetch("modules").fetch("patrol")["decision_count"] = 0
    forged["qualification_id"] =
      Hive::Modules::Migration::PatrolEvidence.digest(
        "qualification", forged.reject { |key, _| key == "qualification_id" }
      )
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::PatrolQualification.from_h(forged)
    end
  end

  private

  def build_qualification(receipts)
    index = Hive::Modules::Migration::PatrolEffectIndex.build(
      receipts: receipts.flat_map(&:effects)
    )
    Hive::Modules::Migration::PatrolQualification.build(
      lane: "deterministic", verified_receipts: receipts,
      effect_index: index, generated_at: NOW + 30
    )
  end

  def complete_receipts(spacing: 1)
    %w[patrol architecture-patrol].flat_map do |module_name|
      10.times.map do |index|
        verified_receipt(
          module_name: module_name, index: index,
          decision_class: index.even? ? "positive" : "negative",
          repository_sha: (index.even? ? "7" : "8") * 40,
          occurred_at: NOW + (index * spacing)
        )
      end
    end
  end

  def verified_receipt(module_name:, index:, decision_class: "positive",
                       repository_sha: "7" * 40, occurred_at: NOW,
                       configuration_digest: nil, run_id: "run-1",
                       effect_status: nil, repository_id: "owner/demo",
                       trigger_id: nil, change_window: nil,
                       decision_index: index)
    projection = projection_for(module_name, decision_index)
    capture = capture_for(
      module_name, decision_index, projection, occurred_at,
      repository_id: repository_id, trigger_id: trigger_id
    )
    effects = if effect_status
      [ effect_receipt(
        occurrence_id: capture.occurrence_id, status: effect_status
      ) ]
    else
      []
    end
    committed_effect_ids = effects.select do |effect|
      effect.intent.authority == "legacy" &&
        %w[committed reconciled].include?(effect.status)
    end.map(&:receipt_id)
    capture = capture_for(
      module_name, decision_index, projection, occurred_at,
      effect_ids: committed_effect_ids, repository_id: repository_id,
      trigger_id: trigger_id
    )
    receipt = Hive::Modules::Migration::PatrolEvidenceReceipt.build(
      run_id: run_id, candidate_sha: "1" * 40,
      catalog_digest: "2" * 64, source_digest: "3" * 64,
      manifest_digest: "4" * 64,
      configuration_digest: configuration_digest ||
        (module_name == "patrol" ? "5" : "a") * 64,
      scenario_manifest_digest: "6" * 64,
      repository: {
        "id" => repository_id, "sha" => repository_sha,
        "change_window" => change_window || "window-#{index % 2}"
      },
      capture: capture, module_projection: projection,
      decision_class: decision_class, effects: effects,
      fault_steps: [ "restart-#{index % 2}" ],
      artifacts: [
        { "kind" => "comparison", "digest" => artifact_digest(index) }
      ],
      reviewer: "reviewer-1", generated_at: occurred_at,
      reviewed_at: occurred_at + 1
    )
    Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
      receipt: receipt, expected_bindings: expected_bindings(receipt)
    )
  end

  def projection_for(module_name, index)
    if module_name == "patrol"
      Hive::Modules::Migration::PatrolDecisionProjection.build(
        module_name: module_name, rationale: "due"
      )
    else
      Hive::Modules::Migration::PatrolDecisionProjection.build(
        module_name: module_name, rationale: "due",
        job_id: "job-#{index}", phase: "discovery"
      )
    end
  end

  def capture_for(module_name, index, projection, occurred_at, effect_ids: [],
                  repository_id: "owner/demo", trigger_id: nil)
    reservation = if module_name == "patrol"
      { "kind" => "ordinary", "id" => "reservation-#{index}" }
    else
      {
        "kind" => "architecture", "id" => "reservation-#{index}",
        "job_id" => "job-#{index}"
      }
    end
    input = if module_name == "patrol"
      { "kind" => "operation", "operation" => "test" }
    else
      { "kind" => "candidate", "job_id" => "job-#{index}", "phase" => "discovery" }
    end
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: module_name,
      project: {
        "project_id" => "project-1", "name" => "demo",
        "repository" => repository_id
      },
      trigger: {
        "kind" => "manual",
        "id" => trigger_id || "manual-#{module_name}-#{index}"
      },
      reservation: reservation, owner: "legacy", owner_epoch: 1,
      selection_input: input, selection: projection,
      outcome_class: "completed", outcome: { "rationale" => "completed" },
      effect_ids: effect_ids, occurred_at: occurred_at,
      recorded_at: occurred_at
    )
  end

  def effect_receipt(occurrence_id:, status:)
    intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol", occurrence_id: occurrence_id,
      authority: "legacy", owner_epoch: 1, sink: "finding",
      target: "finding-1", idempotency_key: "finding-1",
      capability: "finding_write", created_at: NOW
    )
    Hive::Modules::Migration::EffectReceipt.build(
      intent: intent, status: status,
      outcome: status == "unknown" ?
        { "reason" => "dispatch outcome unknown" } :
        { "finding_id" => "finding-1" },
      recorded_at: NOW
    )
  end

  def expected_bindings(receipt)
    {
      "run_id" => receipt.run_id,
      "candidate_sha" => receipt.candidate_sha,
      "catalog_digest" => receipt.catalog_digest,
      "source_digest" => receipt.source_digest,
      "manifest_digest" => receipt.manifest_digest,
      "configuration_digest" => receipt.configuration_digest,
      "scenario_manifest_digest" => receipt.scenario_manifest_digest,
      "repository" => receipt.repository,
      "receipt_id" => receipt.receipt_id,
      "capture_id" => receipt.capture.capture_id,
      "trigger_id" => receipt.capture.trigger.fetch("id"),
      "owner_epoch" => receipt.capture.owner_epoch,
      "module_projection_digest" => Digest::SHA256.hexdigest(
        Hive::Modules::Migration::PatrolEvidence.canonical(
          receipt.module_projection.to_h
        )
      ),
      "decision_class" => receipt.decision_class,
      "effect_receipt_ids" => receipt.effects.map(&:receipt_id),
      "fault_steps" => receipt.fault_steps,
      "artifacts" => receipt.artifacts,
      "reviewer" => receipt.reviewer,
      "generated_at" => receipt.generated_at,
      "reviewed_at" => receipt.reviewed_at
    }
  end

  def artifact_digest(index)
    index.to_s(16).rjust(64, "0")
  end
end
