require "tmpdir"
require "hive/modules/migration/patrol_effect_index"
require "hive/modules/migration/patrol_evidence_receipt"
require "hive/modules/migration/patrol_evidence_verifier"
require "hive/modules/migration/live_bindings_resolver"
require "hive/modules/migration/qualification_run_authority_provider"
require "hive/modules/migration/shadow_comparator"

module PatrolEvidenceScenario
  START = Time.utc(2026, 7, 30, 9, 0, 0)
  CANDIDATE_SHA = "c" * 40
  RUN_ID = "patrol-#{"6" * 64}".freeze
  CANDIDATE = {
    "commit_sha" => CANDIDATE_SHA,
    "artifact_manifest_sha256" => "a" * 64,
    "source_archive_sha256" => "b" * 64,
    "candidate_gem_sha256" => "c" * 64,
    "skills_archive_sha256" => "8" * 64,
    "installed_tree_sha256" => "9" * 64
  }.freeze
  CONTROL = {
    "repository" => "github.com/owner/hive",
    "ref" => "refs/heads/main",
    "commit_sha" => "1" * 40,
    "tree_sha" => "2" * 40,
    "trust_scope" => "trusted_remote",
    "catalog" => {
      "ref" =>
        "test/e2e/fixtures/patrol_qualification/catalog.json",
      "sha256" => "3" * 64
    },
    "harness_manifest_sha256" => "4" * 64,
    "provenance" => {
      "workflow_path" =>
        ".github/workflows/patrol-qualification.yml",
      "workflow_sha" => "1" * 40,
      "run_id" => 123,
      "run_attempt" => 1,
      "action_lock_sha256" => "5" * 64
    }
  }.freeze
  CONFIGURATION_DIGESTS = {
    "patrol" => "d" * 64,
    "architecture-patrol" => "e" * 64
  }.freeze
  PROJECT_BINDING = {
    "project_id" => "project-1",
    "name" => "demo",
    "repository" => "github.com/owner/evidence"
  }.freeze

  private

  def with_qualification(lane: "deterministic",
                         configuration_digests: CONFIGURATION_DIGESTS,
                         candidate_sha: CANDIDATE_SHA,
                         run_id: RUN_ID,
                         scenario_manifest_digest: "f" * 64,
                         project: PROJECT_BINDING,
                         module_selections: nil)
    module_selections ||= module_selection_bindings(
      configuration_digests
    )
    records = qualification_records(
      configuration_digests: configuration_digests,
      project: project
    )
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
        "repository" => project.fetch("repository"),
        "repository_sha" => index.even? ? "1" * 40 : "2" * 40,
        "trigger_digest" => record.fetch("trigger_digest"),
        "record_digest" => record.fetch("semantic_digest"),
        "control" => control_for(decision_class)
      }
    end
    bindings = current_bindings(
      decision_refs: decision_refs,
      expected_legacy_effect_keys: effect_index.legacy_keys,
      lane: lane,
      configuration_digests: configuration_digests,
      candidate_sha: candidate_sha,
      run_id: run_id,
      scenario_manifest_digest: scenario_manifest_digest,
      project: project,
      module_selections: module_selections
    )
    yield records, decision_refs, effect_index, bindings
  end

  def qualification_bundle(lane: "deterministic", lane_result: "passed",
                           failure_reason: nil,
                           configuration_digests: CONFIGURATION_DIGESTS,
                           candidate_sha: CANDIDATE_SHA,
                           run_id: RUN_ID,
                           scenario_manifest_digest: "f" * 64,
                           project: PROJECT_BINDING,
                           module_selections: nil)
    qualification_case(
      lane: lane,
      lane_result: lane_result,
      failure_reason: failure_reason,
      configuration_digests: configuration_digests,
      candidate_sha: candidate_sha,
      run_id: run_id,
      scenario_manifest_digest: scenario_manifest_digest,
      project: project,
      module_selections: module_selections
    ).fetch("bundle")
  end

  def qualification_case(lane: "deterministic",
                         lane_result: "passed",
                         failure_reason: nil,
                         configuration_digests:
                           CONFIGURATION_DIGESTS,
                         candidate_sha: CANDIDATE_SHA,
                         run_id: RUN_ID,
                         scenario_manifest_digest: "f" * 64,
                         project: PROJECT_BINDING,
                         module_selections: nil)
    result = nil
    with_qualification(
      lane: lane,
      configuration_digests: configuration_digests,
      candidate_sha: candidate_sha,
      run_id: run_id,
      scenario_manifest_digest: scenario_manifest_digest,
      project: project,
      module_selections: module_selections
    ) do |records, refs, index, bindings|
      authority = run_authority_document(bindings)
      receipt = build_receipt(
        decision_refs: refs,
        effect_index: index,
        bindings: bindings,
        lane_result: lane_result,
        failure_reason: failure_reason
      )
      result = {
        "authority" => authority,
        "bundle" => {
          "receipt" => receipt.to_h,
          "records" => records
        }
      }
    end
    result
  end

  def qualification_records(configuration_digests: CONFIGURATION_DIGESTS,
                            project: PROJECT_BINDING)
    decision_classes.flat_map do |module_name, classes|
      classes.each_with_index.map do |decision_class, index|
        record_for(
          module_name: module_name,
          index: index,
          decision_class: decision_class,
          configuration_digests: configuration_digests,
          project: project
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

  def record_for(module_name:, index:, decision_class:, module_effect: false,
                 configuration_digests: CONFIGURATION_DIGESTS,
                 project: PROJECT_BINDING)
    trigger = { "kind" => "manual", "id" => "#{module_name}-#{index}" }
    rationale = %w[
      not_due capacity_deferral quota_deferral cooldown_retry
    ].include?(decision_class) ? "not_due" : "due"
    projection = projection_for(module_name, trigger, rationale)
    capture = capture_for(
      module_name,
      trigger,
      projection,
      decision_class: decision_class,
      project: project
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
        configuration_digest: configuration_digests.fetch(module_name),
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

  def capture_for(module_name, trigger, projection, decision_class:,
                  project: PROJECT_BINDING)
    architecture = module_name == "architecture-patrol"
    positive = %w[
      ordinary_positive_finding architecture_positive_thesis
    ].include?(decision_class)
    outcome = if architecture
      {
        "rationale" => projection.rationale,
        "action_count" => positive ? 1 : 0,
        "job_id" => projection.job_id,
        "complete" => true,
        "zero_reason" =>
          decision_class == "clean_negative" ?
            "no_theses" : nil
      }
    else
      {
        "rationale" => projection.rationale,
        "findings" => positive ? 1 : 0,
        "finding_ids" =>
          positive ? [ "finding-#{trigger.fetch('id')}" ] : [],
        "ok" => true,
        "review_complete" => true,
        "features_reviewed" => 1
      }
    end
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: module_name,
      project: project,
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

  def current_bindings(decision_refs:, expected_legacy_effect_keys:,
                       lane: "deterministic",
                       configuration_digests: CONFIGURATION_DIGESTS,
                       candidate_sha: CANDIDATE_SHA,
                       run_id: RUN_ID,
                       scenario_manifest_digest: "f" * 64,
                       project: PROJECT_BINDING,
                       module_selections: nil)
    module_selections ||= module_selection_bindings(
      configuration_digests
    )
    {
      "run_id" => run_id,
      "lane" => lane,
      "candidate" =>
        CANDIDATE.merge("commit_sha" => candidate_sha),
      "control" => CONTROL,
      "configuration_digests" => configuration_digests,
      "project" => project,
      "module_selections" => module_selections,
      "scenario_manifest_digest" => scenario_manifest_digest,
      "artifact_digests" => {
        "bounded_log" => "1" * 64,
        "scenario_manifest" => "2" * 64
      },
      "decision_expectations" => decision_refs.map do |row|
        row.reject { |key, _value| key == "record_digest" }
      end.sort_by { |row| row.fetch("decision_id") },
      "required_matrix" =>
        Hive::Modules::Migration::PatrolEvidenceVerifier::REQUIRED_MATRIX,
      "required_faults" =>
        Hive::Modules::Migration::PatrolEvidenceVerifier::REQUIRED_FAULTS,
      "lane_policy" => lane_policy(lane),
      "artifact_refs" => artifact_refs(lane),
      "expected_legacy_effect_keys" => expected_legacy_effect_keys
    }
  end

  def run_authority_document(bindings)
    keys = %w[
      artifact_digests artifact_refs candidate control
      decision_expectations expected_legacy_effect_keys lane lane_policy
      module_selections project required_faults required_matrix run_id
      scenario_manifest_digest
    ]
    Hive::Modules::Migration::PatrolEvidence.immutable_json(
      bindings.slice(*keys),
      label: "test patrol run authority"
    )
  end

  def qualification_authority_documents(
    configuration_digests: CONFIGURATION_DIGESTS,
    candidate_sha: CANDIDATE_SHA,
    run_id: RUN_ID,
    scenario_manifest_digest: "f" * 64,
    project: PROJECT_BINDING,
    module_selections: nil
  )
    module_selections ||= module_selection_bindings(
      configuration_digests
    )
    %w[deterministic installed].to_h do |lane|
      scenario = qualification_case(
        lane: lane,
        configuration_digests: configuration_digests,
        candidate_sha: candidate_sha,
        run_id: run_id,
        scenario_manifest_digest: scenario_manifest_digest,
        project: project,
        module_selections: module_selections
      )
      [
        [ run_id, lane ],
        scenario.fetch("authority")
      ]
    end
  end

  def qualification_run_authority_provider(
    authority_documents:
      qualification_authority_documents
  )
    lambda do |run_id:, lane:|
      bindings = authority_documents[[ run_id, lane ]]
      if bindings
        Hive::Modules::Migration::
          QualificationRunAuthorityProvider::Outcome.new(
            status: "resolved",
            bindings: bindings,
            issues: [].freeze
          ).freeze
      else
        Hive::Modules::Migration::
          QualificationRunAuthorityProvider::Outcome.new(
            status: "blocked",
            bindings: nil,
            issues:
              [ "qualification_descriptor_missing" ].freeze
          ).freeze
      end
    end
  end

  def lane_policy(lane)
    if lane == "deterministic"
      {
        "credential_bindings" => [],
        "kind" => "source_archive",
        "provider" => "fixture",
        "repository_sha" => "2" * 40,
        "target_ref" =>
          "inputs/candidate/hive-source-#{CANDIDATE_SHA}.tar.gz",
        "executable" => "bin/hive",
        "network" => false,
        "timeout_seconds" => 300
      }
    else
      {
        "credential_bindings" => [ "OPENROUTER_API_KEY" ],
        "kind" => "installed_target",
        "provider" => "openrouter",
        "repository_sha" => "5" * 40,
        "target_ref" =>
          "inputs/installed-target/target.json",
        "executable" => "bin/hive",
        "network" => false,
        "timeout_seconds" => 300
      }
    end
  end

  def artifact_refs(lane)
    {
      "result" => "lanes/#{lane}/result.json",
      "bundle" => "lanes/#{lane}/bundle.json",
      "artifacts" => "lanes/#{lane}/artifacts",
      "repro_json" => "lanes/#{lane}/repro.json",
      "repro_script" => "lanes/#{lane}/repro.sh"
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
      control: bindings.fetch("control"),
      configuration_digests: bindings.fetch("configuration_digests"),
      project: bindings.fetch("project"),
      module_selections: bindings.fetch("module_selections"),
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

  def module_selection_bindings(
    configuration_digests = CONFIGURATION_DIGESTS
  )
    Hive::Modules::Migration::PatrolEvidence::MODULES.sort.to_h do |name|
      marker = name == "patrol" ? "a" : "b"
      [
        name,
        {
          "selection_epoch" => 2,
          "active" => {
            "version" => "0.1.0",
            "catalog_commit" => marker * 40,
            "source_commit" => marker * 40,
            "manifest_digest" => marker * 64,
            "configuration_digest" =>
              configuration_digests.fetch(name)
          }
        }
      ]
    end
  end

  def selection_snapshot(
    selections = module_selection_bindings
  )
    selections.to_h do |name, selection|
      [
        name,
        {
          "schema_version" => 1,
          "name" => name,
          "installed" => true,
          "enabled" => true,
          "epoch" => selection.fetch("selection_epoch"),
          "active" => selection.fetch("active"),
          "previous" => nil,
          "high_water_at" => START.iso8601(6),
          "receipt_digest" => "0" * 64
        }
      ]
    end
  end

  def qualification_live_resolver(
    project_provider: -> { PROJECT_BINDING },
    module_selections: module_selection_bindings,
    authority_documents: nil,
    run_authority_provider: nil
  )
    configuration_digests =
      module_selections.to_h do |name, selection|
        [
          name,
          selection.dig("active", "configuration_digest")
        ]
      end
    authority_documents ||= qualification_authority_documents(
      configuration_digests: configuration_digests,
      module_selections: module_selections
    )
    run_authority_provider ||=
      qualification_run_authority_provider(
        authority_documents: authority_documents
      )
    Hive::Modules::Migration::LiveBindingsResolver.new(
      project_provider: project_provider,
      module_selections:
        selection_snapshot(module_selections),
      run_authority_provider: run_authority_provider
    )
  end

  def qualification_binding_resolution(
    bindings,
    status: "resolved",
    issues: []
  )
    Hive::Modules::Migration::LiveBindingsResolver::Result.new(
      status: status,
      bindings: bindings,
      issues: issues.freeze
    ).freeze
  end
end
