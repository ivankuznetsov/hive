require "digest"
require "json"
require "tmpdir"
require "hive/attempts/record"
require "hive/modules/decision_journal"
require "hive/modules/event_ledger"
require "hive/modules/event_publisher"
require "hive/modules/hook_attempt"
require "hive/modules/migration/qualification_scenario_observations"
require "hive/workflow_package/canonical_json"
require_relative "patrol_evidence_scenario"

module QualificationRunFixture
  include PatrolEvidenceScenario

  COMMIT_SHA = "c" * 40

  def qualification_run_fixture
    source = "source archive\n".b
    gem = "candidate gem\n".b
    skills = "skills archive\n".b
    web = "web archive\n".b
    scenario = "name: patrol-case\nsteps: []\n".b
    installed_files = {
      "inputs/installed-target/bin/hive" => {
        bytes: "#!/usr/bin/env ruby\nputs '{}'\n".b,
        mode: 0o700
      },
      "inputs/installed-target/lib/hive.rb" => {
        bytes: "module Hive; end\n".b,
        mode: 0o600
      }
    }
    installed_files["inputs/installed-target/target.json"] = {
      bytes: canonical(
        "schema" => "hive-release-candidate-installed-target",
        "schema_version" => 1,
        "role" => "candidate",
        "version" => "0.7.0",
        "gem_sha256" => sha(gem),
        "executable" => "bin/hive",
        "skills" => {
          "archive_sha256" => sha(skills),
          "import_root" => "skills"
        }
      ),
      mode: 0o600
    }
    installed_digest = installed_tree_digest(installed_files)
    source_name = "hive-source-#{COMMIT_SHA}.tar.gz"
    gem_name = "hive-cli-0.7.0.gem"
    skills_name = "hive-agent-skills-#{COMMIT_SHA}.tar.gz"
    web_name = "hive-web-0.7.0.tar.gz"
    artifact_manifest = canonical(
      "schema" => "hive-release-candidate-artifacts",
      "schema_version" => 1,
      "candidate_sha" => COMMIT_SHA,
      "hive_version" => "0.7.0",
      "skill_version" => "1",
      "canonical_digest" => "8" * 64,
      "builder_revision" => "9" * 64,
      "files" => {
        source_name => {
          "kind" => "source",
          "sha256" => sha(source),
          "size" => source.bytesize
        },
        gem_name => {
          "kind" => "gem",
          "sha256" => sha(gem),
          "size" => gem.bytesize
        },
        skills_name => {
          "kind" => "skills",
          "sha256" => sha(skills),
          "size" => skills.bytesize
        },
        web_name => {
          "kind" => "web",
          "sha256" => sha(web),
          "size" => web.bytesize
        }
      }
    )
    scenario_manifest = canonical(
      "cases" => [
        {
          "case_id" => "patrol-case",
          "path" => "inputs/scenarios/patrol-case.yml",
          "sha256" => sha(scenario)
        }
      ]
    )
    project = {
      "project_id" => "project-1",
      "name" => "demo",
      "repository" => "github.com/owner/evidence"
    }
    observation_record = record_for(
      module_name: "patrol",
      index: 0,
      decision_class: "ordinary_positive_finding",
      configuration_digests: {
        "patrol" => "d" * 64,
        "architecture-patrol" => "e" * 64
      },
      project: project
    )
    effect_index =
      Hive::Modules::Migration::PatrolEffectIndex.build(
        records: [ observation_record ]
      )
    decision = {
      "decision_id" => observation_record.fetch("decision_id"),
      "module" => "patrol",
      "decision_class" => "ordinary_positive_finding",
      "repository" => "github.com/owner/evidence",
      "repository_sha" => "2" * 40,
      "trigger_digest" =>
        observation_record.fetch("trigger_digest"),
      "control" => "ordinary_positive_finding"
    }
    effect = effect_index.legacy_keys.fetch(0)
    case_row = {
      "case_id" => "patrol-case",
      "scenario_ref" => "inputs/scenarios/patrol-case.yml",
      "scenario_sha256" => sha(scenario),
      "decision_expectations" => [ decision ],
      "expected_legacy_effect_keys" => [ effect ],
      "matrix" => [ "ordinary_positive_finding" ],
      "faults" => [ "after_legacy_capture" ]
    }
    payload = {
      "schema" => "hive-patrol-qualification-run",
      "schema_version" => 1,
      "run_id" => nil,
      "descriptor_sha256" => nil,
      "prepared_at" => "2026-07-30T09:00:00.000000Z",
      "project" => project,
      "module_selections" => qualification_module_selections,
      "candidate" => {
        "commit_sha" => COMMIT_SHA,
        "artifact_manifest_sha256" => sha(artifact_manifest),
        "source_archive_sha256" => sha(source),
        "candidate_gem_sha256" => sha(gem),
        "skills_archive_sha256" => sha(skills),
        "installed_tree_sha256" => installed_digest
      },
      "control" => {
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
      },
      "scenarios" => {
        "manifest_ref" => "inputs/scenarios/manifest.json",
        "manifest_sha256" => sha(scenario_manifest),
        "cases" => [ case_row ]
      },
      "expectations" => {
        "decision_expectations" => [ decision ],
        "expected_legacy_effect_keys" => [ effect ],
        "required_matrix" => [ "ordinary_positive_finding" ],
        "required_faults" => [ "after_legacy_capture" ]
      },
      "lanes" => {
        "deterministic" => {
          "credential_bindings" => [],
          "kind" => "source_archive",
          "provider" => "fixture",
          "repository_sha" => "2" * 40,
          "target_ref" => "inputs/candidate/#{source_name}",
          "executable" => "bin/hive",
          "network" => false,
          "timeout_seconds" => 300
        },
        "installed" => {
          "credential_bindings" => [
            "GITHUB_TOKEN", "OPENROUTER_API_KEY"
          ],
          "kind" => "installed_target",
          "provider" => "openrouter",
          "repository_sha" => "5" * 40,
          "target_ref" => "inputs/installed-target/target.json",
          "executable" => "bin/hive",
          "network" => true,
          "timeout_seconds" => 300
        }
      },
      "artifact_refs" => %w[deterministic installed].to_h do |lane|
        [
          lane,
          {
            "result" => "lanes/#{lane}/result.json",
            "bundle" => "lanes/#{lane}/bundle.json",
            "artifacts" => "lanes/#{lane}/artifacts",
            "repro_json" => "lanes/#{lane}/repro.json",
            "repro_script" => "lanes/#{lane}/repro.sh"
          }
        ]
      end
    }
    seal_qualification_payload!(payload)
    {
      payload: payload,
      descriptor: canonical(payload),
      observation_record: observation_record,
      inputs: {
        "inputs/candidate/manifest.json" => {
          bytes: artifact_manifest, mode: 0o600
        },
        "inputs/candidate/#{source_name}" => {
          bytes: source, mode: 0o600
        },
        "inputs/candidate/#{gem_name}" => {
          bytes: gem, mode: 0o600
        },
        "inputs/candidate/#{skills_name}" => {
          bytes: skills, mode: 0o600
        },
        "inputs/candidate/#{web_name}" => {
          bytes: web, mode: 0o600
        },
        "inputs/scenarios/manifest.json" => {
          bytes: scenario_manifest, mode: 0o600
        },
        "inputs/scenarios/patrol-case.yml" => {
          bytes: scenario, mode: 0o600
        }
      }.merge(installed_files)
    }
  end

  def qualification_module_selections
    %w[architecture-patrol patrol].to_h do |name|
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
              (name == "patrol" ? "d" : "e") * 64
          }
        }
      ]
    end
  end

  def seal_qualification_payload!(payload, derive_run_id: true)
    if derive_run_id
      identity_body = payload.reject do |key, _value|
        %w[run_id descriptor_sha256].include?(key)
      end
      payload["run_id"] =
        "patrol-#{sha(canonical(identity_body))}"
    end
    payload["descriptor_sha256"] = sha(
      canonical(
        payload.reject do |key, _value|
          key == "descriptor_sha256"
        end
      )
    )
    payload
  end

  def qualification_scenario_observations(fixture, lane:)
    payload = fixture.fetch(:payload)
    project = payload.fetch("project")
    selection =
      payload.dig("module_selections", "patrol")
    active = selection.fetch("active")
    record = fixture.fetch(:observation_record)
    capture =
      Hive::Modules::Migration::PatrolCapture.from_h(
        record.fetch("legacy_capture")
      )
    event = qualification_event(project, capture)
    initial_attempt_id =
      "11111111-1111-4111-8111-111111111111"
    subject = {
      "kind" => "module_hook",
      "project_id" => project.fetch("project_id"),
      "module" => "patrol",
      "hook" => "scheduled-scan",
      "event_id" => event.fetch("event_id"),
      "occurrence_id" => event.fetch("event_id"),
      "event_name" => event.fetch("event_name"),
      "module_generation" => active.fetch("source_commit"),
      "configuration_digest" =>
        active.fetch("configuration_digest"),
      "grant_digest" => "f" * 64
    }
    decision = qualification_journal_decision(
      project: project,
      event: event,
      subject: subject,
      attempt_id: initial_attempt_id
    )
    attempts = qualification_attempt_lineage(
      project: project,
      subject: subject,
      selection: selection,
      initial_attempt_id: initial_attempt_id
    )
    effect_index =
      Hive::Modules::Migration::PatrolEffectIndex.build(
        records: [ record ]
      )
    expectation =
      payload.dig(
        "scenarios", "cases", 0, "decision_expectations"
      ).find do |candidate|
        candidate.fetch("decision_id") ==
          record.fetch("decision_id")
      end
    observations = {
      "schema" =>
        "hive-patrol-qualification-scenario-observations",
      "schema_version" => 1,
      "run_id" => payload.fetch("run_id"),
      "lane" => lane,
      "scenario_manifest_sha256" =>
        payload.dig("scenarios", "manifest_sha256"),
      "observations" => [
        {
          "case_id" => "patrol-case",
          "decision_id" => record.fetch("decision_id"),
          "module" => record.fetch("module"),
          "decision_class" =>
            expectation.fetch("decision_class"),
          "repository_sha" =>
            expectation.fetch("repository_sha"),
          "trigger_digest" =>
            record.fetch("trigger_digest"),
          "comparator_semantic_digest" =>
            record.fetch("semantic_digest"),
          "legacy_capture_id" => capture.capture_id,
          "event_id" => event.fetch("event_id"),
          "legacy_effect_keys" => effect_index.legacy_keys,
          "module_effect_keys" => [],
          "fault_checkpoint" => "after_legacy_capture",
          "pre_fault_durable_state_sha256" => "6" * 64,
          "recovered_durable_state_sha256" => "7" * 64,
          "restart_generation" => 1,
          "event" => event,
          "decisions" => [ decision ],
          "attempts" => attempts
        }
      ]
    }
    Hive::Modules::Migration::
      QualificationScenarioObservations.from_h(
        observations
      ).to_h
  end

  def qualification_record_with_alternate_capture(fixture)
    record = fixture.fetch(:observation_record)
    capture =
      Hive::Modules::Migration::PatrolCapture.from_h(
        record.fetch("legacy_capture")
      )
    outcome = JSON.parse(canonical(capture.outcome))
    outcome["findings"] = 0
    outcome["finding_ids"] = []
    alternate =
      Hive::Modules::Migration::PatrolCapture.build(
        module_name: capture.module_name,
        project: capture.project,
        trigger: capture.trigger,
        reservation: capture.reservation,
        owner: capture.owner,
        owner_epoch: capture.owner_epoch,
        selection_input: capture.selection_input,
        selection: capture.selection,
        outcome_class: capture.outcome_class,
        outcome: outcome,
        effect_ids: capture.effect_ids,
        occurred_at: capture.occurred_at,
        recorded_at: capture.recorded_at
      )
    Dir.mktmpdir("qualification-alternate-capture") do |root|
      comparator =
        Hive::Modules::Migration::ShadowComparator.new(
          root: root,
          clock: -> { Time.iso8601(record.fetch("recorded_at")) }
        )
      comparator.record!(
        module_name: record.fetch("module"),
        trigger: record.fetch("trigger"),
        module_projection: record.fetch("module_decision"),
        configuration_digest:
          record.fetch("configuration_digest"),
        occurred_at: record.fetch("occurred_at"),
        legacy_capture: alternate,
        legacy_effects: record.fetch("legacy_effects"),
        module_effects: record.fetch("module_effects")
      )
    end
  end

  def qualification_event(project, capture)
    Dir.mktmpdir("qualification-event") do |root|
      ledger = Hive::Modules::EventLedger.new(root: root)
      publisher = Hive::Modules::EventPublisher.new(
        ledger_factory: ->(_entry) { ledger },
        clock: -> { PatrolEvidenceScenario::START + 1 }
      )
      publisher.prepare_patrol_finalized(
        {
          "project_id" => project.fetch("project_id"),
          "name" => project.fetch("name")
        },
        capture,
        schedule: "*/15 * * * *"
      )
    end
  end

  def qualification_journal_decision(project:, event:, subject:,
                                     attempt_id:)
    Dir.mktmpdir("qualification-decision") do |root|
      journal = Hive::Modules::DecisionJournal.new(
        root: root,
        id_generator: -> { "qualification-decision" }
      )
      journal.append(
        "project_id" => project.fetch("project_id"),
        "project" => project.fetch("name"),
        "module" => subject.fetch("module"),
        "hook" => subject.fetch("hook"),
        "event_id" => event.fetch("event_id"),
        "event_name" => event.fetch("event_name"),
        "evaluated_at" =>
          (PatrolEvidenceScenario::START + 2).iso8601(6),
        "outcome" => "launch",
        "reason" => "admitted",
        "binding_digest" => "b" * 64,
        "cursor_before" => nil,
        "cursor_after" => event.fetch("event_id"),
        "module_generation" =>
          subject.fetch("module_generation"),
        "configuration_digest" =>
          subject.fetch("configuration_digest"),
        "grant_digest" => subject.fetch("grant_digest"),
        "concurrency" => "allow",
        "attempt_id" => attempt_id,
        "task_id" => nil,
        "artifacts" => [],
        "retry" => nil
      )
    end
  end

  def qualification_attempt_lineage(project:, subject:, selection:,
                                    initial_attempt_id:)
    generation =
      Hive::Modules::HookAttempt.run_id_for(subject)
    ownership_generation =
      "#{selection.fetch('selection_epoch')}:" \
      "#{selection.dig('active', 'source_commit')}"
    first = qualification_attempt_record(
      project: project,
      subject: subject,
      attempt_id: initial_attempt_id,
      predecessor_attempt_id: nil,
      retry_charge: 0,
      task_generation: generation,
      ownership_generation: ownership_generation,
      task_input_epoch: selection.fetch("selection_epoch")
    ).with(
      "state" => "lost",
      "loss" => {
        "reason" => "lease_expired",
        "at" =>
          (PatrolEvidenceScenario::START + 3).iso8601(6)
      }
    )
    successor_attempt_id =
      "22222222-2222-4222-8222-222222222222"
    retry_generation = Digest::SHA256.hexdigest(
      [
        "hive-module-hook-retry-v1",
        generation,
        1
      ].join("\0")
    )
    successor = qualification_attempt_record(
      project: project,
      subject: subject,
      attempt_id: successor_attempt_id,
      predecessor_attempt_id: initial_attempt_id,
      retry_charge: 1,
      task_generation: retry_generation,
      ownership_generation: ownership_generation,
      task_input_epoch: selection.fetch("selection_epoch")
    )
    receipt = {
      "attempt_id" => successor_attempt_id,
      "task_generation" => retry_generation,
      "ownership_generation" => ownership_generation,
      "task_input_epoch" => selection.fetch("selection_epoch"),
      "outcome" => "succeeded",
      "exit_status" => 0,
      "started_at" =>
        (PatrolEvidenceScenario::START + 4).iso8601(6),
      "ended_at" =>
        (PatrolEvidenceScenario::START + 5).iso8601(6),
      "final_checkpoint" => {
        "revision" => "a" * 40,
        "progress_token" => subject.fetch("event_id")
      },
      "output_references" => [],
      "log_reference" => {
        "path" => "logs/qualification.frames",
        "size" => 0,
        "sha256" => "0" * 64
      }
    }
    successor = successor.with(
      "state" => "terminal",
      "outcome" => "succeeded",
      "started_at" => receipt.fetch("started_at"),
      "ended_at" => receipt.fetch("ended_at"),
      "receipt" => receipt
    )
    [
      qualification_attempt_projection(first),
      qualification_attempt_projection(successor)
    ]
  end

  def qualification_attempt_record(project:, subject:, attempt_id:,
                                   predecessor_attempt_id:,
                                   retry_charge:, task_generation:,
                                   ownership_generation:,
                                   task_input_epoch:)
    Hive::Attempts::Record.launching(
      attempt_id: attempt_id,
      request_id: "module:#{subject.fetch('event_id')}",
      predecessor_attempt_id: predecessor_attempt_id,
      task_id: nil,
      project: project.fetch("name"),
      task_slug: "module-patrol-scheduled-scan",
      intended_stage: "module-hook",
      task_generation: task_generation,
      progress_token: subject.fetch("event_id"),
      provider: "module",
      worker_argv: [ "hive", "__module-hook" ],
      claim_capability_digest: "9" * 64,
      starting_revision:
        subject.fetch("module_generation"),
      retry_charge: retry_charge,
      inherited_outputs: [],
      now: PatrolEvidenceScenario::START,
      launch_timeout_sec: 30,
      ownership_generation: ownership_generation,
      task_input_epoch: task_input_epoch,
      subject: subject
    )
  end

  def qualification_attempt_projection(record)
    value = record.to_h.slice(
      "attempt_id", "predecessor_attempt_id", "retry_charge",
      "state", "outcome", "task_generation",
      "ownership_generation", "task_input_epoch", "subject",
      "receipt", "loss"
    )
    value["receipt_sha256"] =
      value["receipt"] && sha(canonical(value["receipt"]))
    value["projection_sha256"] = sha(canonical(value))
    value
  end

  def installed_tree_digest(files)
    digest = Digest::SHA256.new
    digest << "hive-installed-tree-v1\0"
    files.sort.each do |path, entry|
      relative = path.delete_prefix(
        "inputs/installed-target/"
      )
      bytes = entry.fetch(:bytes)
      mode = entry.fetch(:mode)
      digest << relative << "\0"
      digest << mode.to_s(8) << "\0"
      digest << bytes.bytesize.to_s << "\0"
      digest << sha(bytes) << "\0"
    end
    digest.hexdigest
  end

  def canonical(value)
    Hive::WorkflowPackage::CanonicalJSON.generate(value)
  end

  def sha(bytes)
    Digest::SHA256.hexdigest(bytes)
  end
end
