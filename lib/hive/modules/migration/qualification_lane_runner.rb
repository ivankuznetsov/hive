require "digest"
require "fileutils"
require "json"
require "shellwords"
require "tmpdir"
require "time"
require "hive/errors"
require "hive/managed_directory"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/patrol_effect_index"
require "hive/modules/migration/patrol_evidence_receipt"
require "hive/modules/migration/patrol_evidence_verifier"
require "hive/modules/migration/qualification_installed_target"
require "hive/modules/migration/qualification_checkpoint_verifier"
require "hive/modules/migration/qualification_lane_result"
require "hive/modules/migration/qualification_provider_broker"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/modules/migration/qualification_scenario_actuals"
require "hive/modules/migration/qualification_scenario_evidence_collector"
require "hive/modules/migration/qualification_scenario_observations"
require "hive/modules/migration/qualification_scenario_oracle"
require "hive/modules/migration/qualification_scenario_orchestrator"
require "hive/modules/migration/qualification_scenario_process"
require "hive/modules/migration/qualification_scenario_request"
require "hive/modules/migration/qualification_scenario_recovery_evidence"
require "hive/modules/migration/qualification_scenario_input"
require "hive/modules/migration/qualification_source_materializer"
require "hive/modules/migration/shadow_comparator"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Trusted host controller for one descriptor-owned qualification lane.
      #
      # It reconstructs both exact candidate targets, runs each stimulus in an
      # isolated candidate process, binds raw actuals through the host oracle,
      # verifies the complete receipt, and publishes result.json last.
      class QualificationLaneRunner
        MAX_INSTALLED_FILES =
          MigrationRepository::MAX_QUALIFICATION_FILES
        MAX_INSTALLED_DEPTH =
          MigrationRepository::MAX_QUALIFICATION_DEPTH
        REVIEWER = "hive-qualification-oracle".freeze
        REPRO_SCHEMA =
          "hive-patrol-qualification-repro".freeze
        PROCESS_SCHEMA =
          "hive-patrol-qualification-process-results".freeze

        Authority = Data.define(
          :descriptor, :target_sha256, :source_bytes,
          :installed_files, :scenario_manifest_bytes,
          :scenarios
        )
        Materialized = Data.define(
          :source_root, :installed_root, :candidate_root,
          :executable
        )

        class LaneFailure < StandardError
          attr_reader :status, :reason, :exit_code

          def initialize(status:, reason:, exit_code: nil)
            @status = status
            @reason = reason
            @exit_code = exit_code
            super(reason)
          end
        end
        private_constant :LaneFailure

        class RetryableProviderFailure < StandardError
          attr_reader :reason

          def initialize(reason)
            @reason = reason.to_s.freeze
            super("patrol qualification provider is retryable")
          end
        end
        private_constant :RetryableProviderFailure

        def initialize(
          repository:,
          clock: -> { Time.now.utc },
          monotonic: lambda {
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          },
          environment: ENV,
          source_materializer:
            QualificationSourceMaterializer.new,
          installed_materializer:
            QualificationInstalledTarget.new,
          scenario_process:
            QualificationScenarioProcess.new,
          scenario_orchestrator: nil,
          evidence_collector:
            QualificationScenarioEvidenceCollector.new,
          checkpoint_verifier:
            QualificationCheckpointVerifier.new,
          recovery_evidence:
            QualificationScenarioRecoveryEvidence.new,
          oracle: QualificationScenarioOracle.new,
          verifier: PatrolEvidenceVerifier,
          provider_broker_factory: lambda { |**arguments|
            QualificationProviderBroker.new(**arguments)
          }
        )
          @repository = repository
          @clock = clock
          @monotonic = monotonic
          @environment = environment
          @source_materializer = source_materializer
          @installed_materializer = installed_materializer
          @scenario_process = scenario_process
          @scenario_orchestrator =
            scenario_orchestrator ||
              QualificationScenarioOrchestrator.new(
                process: scenario_process,
                monotonic: monotonic
              )
          @evidence_collector = evidence_collector
          @checkpoint_verifier = checkpoint_verifier
          @recovery_evidence = recovery_evidence
          @oracle = oracle
          @verifier = verifier
          @provider_broker_factory =
            provider_broker_factory
        end

        def call(run_id:, lane:, live_authorized: false)
          authority = load_authority(run_id, lane)
          descriptor = authority.descriptor
          existing = load_existing(
            run_id,
            lane,
            authority.target_sha256
          )
          return existing if existing

          started_at = utc_time(@clock.call)
          if lane == "installed"
            return publish_blocked(
              authority,
              lane: lane,
              started_at: started_at,
              reason: "live_lane_not_authorized"
            ) unless live_authorized

            provider_credential = live_credential(
              descriptor.lane_policy(lane)
            )
            return publish_blocked(
              authority,
              lane: lane,
              started_at: started_at,
              reason: "credentials_unavailable"
            ) unless provider_credential
          else
            provider_credential = nil
          end

          execute_lane(
            authority,
            lane: lane,
            started_at: started_at,
            provider_credential: provider_credential
          )
        rescue RetryableProviderFailure => error
          publish_blocked(
            authority,
            lane: lane,
            started_at: started_at,
            reason: error.reason
          )
        rescue LaneFailure => error
          publish_failure(
            authority,
            lane: lane,
            started_at: started_at,
            failure: error
          )
        end

        private

        def execute_lane(
          authority, lane:, started_at:, provider_credential:
        )
          descriptor = authority.descriptor
          policy = descriptor.lane_policy(lane)
          deadline =
            @monotonic.call + policy.fetch("timeout_seconds")
          completed = nil
          process_rows = []
          host_evidence = []
          process_generations = []
          recovery_evidence = []
          provider_brokers = []
          Dir.mktmpdir("hive-patrol-qualification-") do |workspace|
            File.chmod(0o700, workspace)
            begin
              materialized = materialize_targets(
                workspace,
                authority,
                lane: lane
              )
              directory = prepare_workspace(
                workspace,
                authority
              )
              actuals = execute_scenarios(
                workspace: workspace,
                directory: directory,
                materialized: materialized,
                authority: authority,
                lane: lane,
                policy: policy,
                provider_credential: provider_credential,
                deadline: deadline,
                process_rows: process_rows,
                host_evidence: host_evidence,
                process_generations: process_generations,
                recovery_evidence: recovery_evidence,
                provider_brokers: provider_brokers
              )
              seal_provider_brokers!(provider_brokers)
              validate_provider_evidence!(
                authority,
                lane: lane,
                process_generations: process_generations,
                provider_brokers: provider_brokers
              )
              observations = @oracle.call(
                descriptor: descriptor,
                lane: lane,
                actuals: actuals,
                recovery_evidence: recovery_evidence
              )
              records = load_comparator_records(
                workspace,
                authority.scenarios
              )
              completed = build_completed_capture(
                authority: authority,
                lane: lane,
                started_at: started_at,
                observations: observations,
                records: records,
                process_rows: process_rows,
                host_evidence: host_evidence,
                process_generations: process_generations,
                recovery_evidence: recovery_evidence,
                provider_brokers: provider_brokers
              )
            rescue QualificationScenarioOrchestrator::
                     ProviderFailure => failure
              seal_provider_brokers!(provider_brokers)
              raise RetryableProviderFailure.new(
                failure.reason
              ) if failure.retryable

              completed = build_failed_capture(
                authority: authority,
                lane: lane,
                started_at: started_at,
                failure: LaneFailure.new(
                  status: "failed",
                  reason: "provider_failed",
                  exit_code: Hive::ExitCodes::SOFTWARE
                ),
                process_rows: process_rows,
                provider_brokers: provider_brokers
              )
            rescue LaneFailure => failure
              seal_provider_brokers!(provider_brokers)
              completed = build_failed_capture(
                authority: authority,
                lane: lane,
                started_at: started_at,
                failure: failure,
                process_rows: process_rows,
                provider_brokers: provider_brokers
              )
            rescue QualificationScenarioProcess::
                     PostSpawnFailure
              seal_provider_brokers!(provider_brokers)
              completed = build_failed_capture(
                authority: authority,
                lane: lane,
                started_at: started_at,
                failure: LaneFailure.new(
                  status: "failed",
                  reason: "candidate_execution_failed",
                  exit_code: Hive::ExitCodes::SOFTWARE
                ),
                process_rows: process_rows,
                provider_brokers: provider_brokers
              )
            rescue Hive::ConfigError, KeyError, NoMethodError,
                   TypeError
              seal_provider_brokers!(provider_brokers)
              completed = build_failed_capture(
                authority: authority,
                lane: lane,
                started_at: started_at,
                failure: LaneFailure.new(
                  status: "failed",
                  reason: "evidence_verification_failed",
                  exit_code: 1
                ),
                process_rows: process_rows,
                provider_brokers: provider_brokers
              )
            rescue StandardError
              seal_provider_brokers!(provider_brokers)
              completed = build_failed_capture(
                authority: authority,
                lane: lane,
                started_at: started_at,
                failure: LaneFailure.new(
                  status: "failed",
                  reason: "internal_error",
                  exit_code: 1
                ),
                process_rows: process_rows,
                provider_brokers: provider_brokers
              )
            ensure
              seal_provider_brokers!(provider_brokers)
            end
          end
          publish_completed(
            authority,
            lane: lane,
            completed: completed
          )
        end

        def materialize_targets(workspace, authority, lane:)
          descriptor = authority.descriptor
          targets = File.join(workspace, "targets")
          Dir.mkdir(targets, 0o700)
          source = @source_materializer.materialize(
            authority.source_bytes,
            destination: File.join(targets, "source"),
            executable_ref:
              descriptor
                .lane_policy("deterministic")
                .fetch("executable")
          )
          installed = @installed_materializer.materialize(
            files: authority.installed_files,
            destination: File.join(targets, "installed"),
            expected_tree_sha256:
              descriptor.candidate.fetch(
                "installed_tree_sha256"
              ),
            expected_gem_sha256:
              descriptor.candidate.fetch(
                "candidate_gem_sha256"
              ),
            expected_skills_sha256:
              descriptor.candidate.fetch(
                "skills_archive_sha256"
              ),
            expected_executable:
              descriptor
                .lane_policy("installed")
                .fetch("executable")
          )
          expected_source = File.join(targets, "source")
          expected_installed = File.join(targets, "installed")
          unless
            source.root == expected_source &&
              installed.root == expected_installed &&
              installed.tree_sha256 ==
                descriptor.candidate.fetch(
                  "installed_tree_sha256"
                )
            raise Hive::ConfigError,
                  "patrol qualification materialized target changed"
          end
          executable =
            if lane == "deterministic"
              File.join(
                source.root,
                descriptor
                  .lane_policy(lane)
                  .fetch("executable")
              )
            else
              installed.executable
            end
          Materialized.new(
            source_root: source.root,
            installed_root: installed.root,
            candidate_root:
              lane == "deterministic" ?
                source.root : installed.package_root,
            executable: executable
          ).freeze
        end

        def prepare_workspace(workspace, authority)
          directory = Hive::ManagedDirectory.new(
            root: workspace,
            label: "patrol qualification lane workspace"
          )
          descriptor = authority.descriptor
          directory.atomic_write(
            descriptor.scenarios.fetch("manifest_ref"),
            authority.scenario_manifest_bytes,
            mode: 0o600,
            expected_absent: true
          )
          authority.scenarios.each do |row|
            directory.atomic_write(
              row.fetch(:scenario_ref),
              row.fetch(:bytes),
              mode: 0o600,
              expected_absent: true
            )
            directory.ensure_directory(
              "cases/#{row.fetch(:case_id)}"
            )
            directory.ensure_directory(
              "cases/#{row.fetch(:case_id)}/sandbox"
            )
          end
          directory.ensure_directory("requests")
          directory
        end

        def execute_scenarios(
          workspace:, directory:, materialized:, authority:,
          lane:, policy:, provider_credential:, deadline:,
          process_rows:, host_evidence:, process_generations:,
          recovery_evidence:, provider_brokers:
        )
          actuals = []
          authority.scenarios.each do |row|
            remaining = deadline - @monotonic.call
            if remaining <= 0
              raise LaneFailure.new(
                status: "timeout",
                reason: "lane_timeout"
              )
            end
            scenario = QualificationScenarioInput.load(
              row.fetch(:bytes),
              expected_case_id: row.fetch(:case_id)
            )
            case_root = File.join(
              workspace,
              "cases",
              row.fetch(:case_id)
            )
            sandbox_root = File.join(case_root, "sandbox")
            hive_home = File.join(
              sandbox_root,
              "hive-home"
            )
            result = @scenario_orchestrator.call(
              case_id: row.fetch(:case_id),
              recovery_plan:
                scenario.faults.fetch(0, nil) ||
                  (
                    scenario.operation == "reconciliation_failure" ?
                      scenario.operation : nil
                  ),
              sandbox_root: sandbox_root,
              state_roots: lambda {
                {
                  "hive_home" => hive_home,
                  "hive_state" =>
                    File.join(sandbox_root, "hive-state"),
                  "repository" =>
                    File.join(sandbox_root, "repository")
                }
              },
              timeout_seconds: [
                remaining,
                policy.fetch("timeout_seconds")
              ].min,
              prepare_generation: lambda do |generation:, stop_after:|
                request = write_request(
                  directory,
                  authority.descriptor,
                  row,
                  generation: generation,
                  stop_after: stop_after
                )
                {
                  request_sha256: request.fetch(:sha256),
                  process_arguments: {
                    executable: materialized.executable,
                    argv: [
                      "__patrol-qualification-scenario",
                      "--workspace", workspace,
                      "--request", request.fetch(:ref)
                    ],
                    workspace: workspace,
                    source_root: materialized.source_root,
                    installed_root: materialized.installed_root,
                    candidate_root:
                      materialized.candidate_root,
                    case_root: case_root,
                    request_ref: request.fetch(:ref),
                    scenario_ref: row.fetch(:scenario_ref),
                    network: policy.fetch("network"),
                    provider_binding:
                      build_provider_binding(
                        workspace: workspace,
                        descriptor: authority.descriptor,
                        lane: lane,
                        case_id: row.fetch(:case_id),
                        generation: generation,
                        request_sha256:
                          request.fetch(:sha256),
                        provider_credential:
                          provider_credential,
                        deadline: deadline,
                        provider_brokers:
                          provider_brokers
                      ),
                    hive_home: hive_home
                  }
                }.freeze
              end,
              verify_checkpoint: lambda do |generation:, checkpoint:,
                                               after_snapshot:, **|
                @checkpoint_verifier.call(
                  case_id: row.fetch(:case_id),
                  generation: generation,
                  checkpoint: checkpoint,
                  snapshot: after_snapshot,
                  sandbox_root: sandbox_root,
                  scenario_input: scenario
                )
              end,
              final_output_sha256: lambda do |generation:, **|
                output_ref = scenario_output_ref(
                  row.fetch(:case_id),
                  generation
                )
                Digest::SHA256.hexdigest(
                  directory.read(
                    output_ref,
                    max_bytes:
                      QualificationScenarioActuals::MAX_BYTES
                  )
                )
              end,
              record_process: lambda do |case_id:, generation:,
                                            planned_checkpoint:,
                                            process:|
                process_rows << raw_process_projection(
                  case_id,
                  generation: generation,
                  planned_checkpoint: planned_checkpoint,
                  process: process
                )
              end
            )
            process_rows.slice!(
              -result.generation_count,
              result.generation_count
            )
            process_rows.concat(
              result.generations.map do |generation|
                process_projection(
                  row.fetch(:case_id),
                  generation
                )
              end
            )
            process_generations << result
            final_generation = result.generation_count
            output_ref =
              scenario_output_ref(
                row.fetch(:case_id),
                final_generation
              )
            actual =
              QualificationScenarioActuals.load(
                directory.read(
                  output_ref,
                  max_bytes:
                    QualificationScenarioActuals::MAX_BYTES
                )
              )
            unless actual.actuals.length == 1
              raise Hive::ConfigError,
                    "patrol qualification candidate actuals are ambiguous"
            end
            terminal = @evidence_collector.call(
              case_id: row.fetch(:case_id),
              sandbox_root: sandbox_root,
              candidate_row: actual.actuals.fetch(0)
            )
            host_evidence << terminal
            recovery_evidence << @recovery_evidence.call(
              result: result,
              scenario_input: scenario,
              candidate_row: actual.actuals.fetch(0),
              terminal_evidence: terminal
            )
            actuals << actual
          end
          actuals.freeze
        end

        def build_provider_binding(
          workspace:, descriptor:, lane:, case_id:, generation:,
          request_sha256:, provider_credential:, deadline:,
          provider_brokers:
        )
          return nil if lane == "deterministic"
          unless
            lane == "installed" &&
              provider_credential.is_a?(String) &&
              !provider_credential.empty?
            raise Hive::ConfigError,
                  "patrol qualification provider is unavailable"
          end
          broker = @provider_broker_factory.call(
            workspace: workspace,
            run_id: descriptor.run_id,
            lane: lane,
            case_id: case_id,
            generation: generation,
            scenario_request_sha256: request_sha256,
            deadline: deadline,
            api_key: provider_credential,
            model:
              descriptor
                .lane_policy(lane)
                .fetch("model")
          )
          unless
            broker.respond_to?(:binding) &&
              broker.respond_to?(:seal!) &&
              broker.respond_to?(:sealed?) &&
              broker.respond_to?(:transcript)
            raise Hive::ConfigError,
                  "patrol qualification provider is unavailable"
          end
          provider_brokers << broker
          broker.binding
        end

        def seal_provider_brokers!(brokers)
          brokers.each do |broker|
            broker.seal! unless broker.sealed?
          end
          true
        end

        def validate_provider_evidence!(
          authority, lane:, process_generations:,
          provider_brokers:
        )
          if lane == "deterministic"
            unless
              provider_brokers.empty? &&
                process_generations.all? do |result|
                  result.generations.all? do |generation|
                    process = generation.receipt.process
                    process.fetch("provider_call_count").zero? &&
                      process.fetch(
                        "provider_evidence_sha256"
                      ).nil? &&
                      process.fetch("provider_failure").nil?
                  end
                end
              raise Hive::ConfigError,
                    "deterministic qualification used a provider"
            end
            return true
          end

          transcripts = provider_brokers.to_h do |broker|
            value = broker.transcript
            key = [
              value.fetch("case_id"),
              value.fetch("generation")
            ]
            if value.fetch("run_id") !=
                 authority.descriptor.run_id ||
               value.fetch("lane") != lane ||
               value.fetch("model") !=
                 authority.descriptor
                   .lane_policy(lane)
                   .fetch("model")
              raise Hive::ConfigError,
                    "patrol qualification provider evidence changed"
            end
            [ key, value ]
          end
          expected_count =
            process_generations.sum(&:generation_count)
          unless
            transcripts.length == provider_brokers.length &&
              transcripts.length == expected_count
            raise Hive::ConfigError,
                  "patrol qualification provider evidence is incomplete"
          end
          process_generations.each do |result|
            result.generations.each do |generation|
              process = generation.receipt.process
              transcript = transcripts.fetch(
                [ result.case_id, generation.generation ]
              )
              unless
                transcript.fetch("failure").nil? &&
                  transcript.fetch("transcript_sha256") ==
                    process.fetch(
                      "provider_evidence_sha256"
                    ) &&
                  transcript.fetch("call_count") ==
                    process.fetch("provider_call_count") &&
                  transcript.fetch(
                    "scenario_request_sha256"
                  ) ==
                    generation.receipt.to_h.fetch(
                      "request_sha256"
                    )
                raise Hive::ConfigError,
                      "patrol qualification provider evidence changed"
              end
              expected_kind =
                provider_kind(
                  authority,
                  case_id: result.case_id
                )
              unless
                transcript.fetch("calls").all? do |call|
                  call.fetch("kind") == expected_kind
                end
                raise Hive::ConfigError,
                      "patrol qualification provider kind changed"
              end
            end
          end
          required_provider_cases(authority).each do |case_id|
            result = process_generations.find do |candidate|
              candidate.case_id == case_id
            end
            final = transcripts.fetch(
              [ case_id, result.generation_count ]
            )
            unless final.fetch("call_count") == 1
              raise Hive::ConfigError,
                    "patrol qualification provider call is missing"
            end
          end
          true
        rescue KeyError, NoMethodError
          raise Hive::ConfigError,
                "patrol qualification provider evidence is incomplete"
        end

        def provider_kind(authority, case_id:)
          row =
            authority.descriptor.scenarios.fetch("cases").find do |item|
              item.fetch("case_id") == case_id
            end
          modules = row.fetch("decision_expectations").map do |decision|
            decision.fetch("module")
          end.uniq
          unless modules.length == 1
            raise Hive::ConfigError,
                  "patrol qualification provider plan is malformed"
          end
          modules.fetch(0) == "patrol" ?
            "ordinary_findings" : "architecture_theses"
        end

        def required_provider_cases(authority)
          controls = %w[
            architecture_positive_thesis clean_negative
            ordinary_positive_finding
          ]
          authority.descriptor.scenarios.fetch("cases").filter_map do |row|
            values = row.fetch("decision_expectations").map do |decision|
              decision.fetch("control")
            end
            row.fetch("case_id") unless
              (values & controls).empty?
          end.freeze
        end

        def provider_artifacts(provider_brokers)
          artifacts = {}
          provider_brokers.each do |broker|
            transcript = broker.transcript
            ref =
              "provider-transcripts/" \
                "#{transcript.fetch('case_id')}/" \
                "generation-#{transcript.fetch('generation')}.json"
            if artifacts.key?(ref)
              raise Hive::ConfigError,
                    "patrol qualification provider evidence is duplicated"
            end
            artifacts[ref] = canonical(transcript)
          end
          artifacts.freeze
        end

        def write_request(
          directory, descriptor, row, generation:, stop_after:
        )
          case_id = row.fetch(:case_id)
          output_ref = scenario_output_ref(case_id, generation)
          value = {
            "schema" => QualificationScenarioRequest::SCHEMA,
            "schema_version" =>
              QualificationScenarioRequest::SCHEMA_VERSION,
            "case_id" => case_id,
            "generation" => generation,
            "stop_after" => stop_after,
            "scenario_sha256" => row.fetch(:scenario_sha256),
            "scenario_ref" => row.fetch(:scenario_ref),
            "package_root_ref" => "targets/candidate",
            "sandbox_root_ref" =>
              "cases/#{case_id}/sandbox",
            "output_ref" => output_ref,
            "project" => descriptor.project
          }
          bytes = QualificationScenarioRequest.canonical(value)
          QualificationScenarioRequest.load(bytes)
          directory.ensure_directory("requests/#{case_id}")
          directory.ensure_directory(
            "cases/#{case_id}/generations/#{generation}/output"
          )
          ref =
            "requests/#{case_id}/generation-#{generation}.json"
          directory.atomic_write(
            ref,
            bytes,
            mode: 0o600,
            expected_absent: true
          )
          {
            ref: ref.freeze,
            output_ref: output_ref,
            sha256: Digest::SHA256.hexdigest(bytes).freeze
          }.freeze
        end

        def scenario_output_ref(case_id, generation)
          "cases/#{case_id}/generations/#{generation}/output/" \
            "scenario-actuals.json"
        end

        def load_comparator_records(workspace, scenarios)
          records = scenarios.flat_map do |row|
            root = File.join(
              workspace,
              "cases",
              row.fetch(:case_id),
              "sandbox",
              "hive-state",
              "module-runtime",
              "migration",
              "shadow"
            )
            ShadowComparator.new(root: root).each_record.to_a
          end
          ids = records.map { |record| record.fetch("decision_id") }
          unless records.any? &&
                 ids.uniq.length == ids.length
            raise Hive::ConfigError,
                  "patrol qualification comparator evidence is malformed"
          end
          records.freeze
        end

        def build_completed_capture(
          authority:, lane:, started_at:, observations:,
          records:, process_rows:, host_evidence:,
          process_generations:, recovery_evidence:,
          provider_brokers:
        )
          descriptor = authority.descriptor
          ended_at = [ utc_time(@clock.call), started_at ].max
          if
            ended_at - started_at >
              descriptor
                .lane_policy(lane)
                .fetch("timeout_seconds")
            raise LaneFailure.new(
              status: "timeout",
              reason: "lane_timeout"
            )
          end
          result = QualificationLaneResult.build(
            run_id: descriptor.run_id,
            lane: lane,
            status: "passed",
            started_at: started_at,
            ended_at: ended_at,
            target_sha256: authority.target_sha256,
            exit_code: 0
          )
          repro_json = repro_json(
            descriptor,
            lane: lane,
            target_sha256: authority.target_sha256
          )
          repro_script = repro_script(descriptor, lane: lane)
          artifacts = {
            "process-results.json" =>
              canonical(
                "schema" => PROCESS_SCHEMA,
                "schema_version" => 1,
                "run_id" => descriptor.run_id,
                "lane" => lane,
                "processes" => process_rows
              ),
            "scenario-observations.json" =>
              QualificationScenarioObservations.canonical(
                observations.to_h
              )
          }.freeze
          artifacts = artifacts.merge(
            host_evidence.to_h do |projection|
              [
                "host-evidence/#{projection.case_id}.json",
                canonical(projection.to_h)
              ]
            end
          ).freeze
          artifacts = artifacts.merge(
            process_generations.to_h do |result|
              [
                "process-generations/#{result.case_id}.json",
                canonical(result.to_h)
              ]
            end
          ).merge(
            recovery_evidence.to_h do |projection|
              [
                "host-recovery/#{projection.case_id}.json",
                canonical(projection.to_h)
              ]
            end
          ).merge(
            provider_artifacts(provider_brokers)
          ).freeze
          artifact_digests = artifact_digests(
            result: result,
            artifacts: artifacts,
            repro_json: repro_json,
            repro_script: repro_script
          )
          effect_index = PatrolEffectIndex.build(
            records: records
          )
          decision_refs = receipt_decisions(
            descriptor,
            observations
          )
          observed_times = records.flat_map do |record|
            %w[occurred_at recorded_at].map do |key|
              utc_time(record.fetch(key))
            end
          end
          generated_at = [
            ended_at,
            observed_times.max
          ].compact.max
          receipt = PatrolEvidenceReceipt.build(
            run_id: descriptor.run_id,
            lane: lane,
            lane_result: "passed",
            candidate: descriptor.candidate,
            control: descriptor.control,
            configuration_digests:
              configuration_digests(descriptor),
            project: descriptor.project,
            module_selections: descriptor.module_selections,
            scenario_manifest_digest:
              descriptor.scenarios.fetch("manifest_sha256"),
            decision_refs: decision_refs,
            matrix:
              descriptor.expectations.fetch("required_matrix"),
            faults:
              descriptor.expectations.fetch("required_faults"),
            restart_count:
              observations.observations.map do |row|
                row.fetch("restart_generation")
              end.max,
            effect_index_digest: effect_index.digest,
            expected_legacy_effect_keys:
              descriptor.expectations.fetch(
                "expected_legacy_effect_keys"
              ),
            artifact_digests: artifact_digests,
            reviewer: REVIEWER,
            generated_at: generated_at,
            reviewed_at: generated_at,
            observed_started_at:
              observed_times.min || started_at,
            observed_ended_at:
              observed_times.max || ended_at
          )
          verification = @verifier.verify(
            receipt: receipt,
            records: records,
            resolution: resolved_bindings(
              descriptor,
              lane: lane,
              artifact_digests: artifact_digests
            )
          )
          unless verification.verified?
            raise LaneFailure.new(
              status: "failed",
              reason: "evidence_verification_failed",
              exit_code: 1
            )
          end
          {
            result: result,
            bundle: canonical(
              "receipt" => receipt.to_h,
              "records" => records
            ),
            artifacts: artifacts,
            repro_json: repro_json,
            repro_script: repro_script
          }.freeze
        end

        def build_failed_capture(
          authority:, lane:, started_at:, failure:, process_rows:,
          provider_brokers: []
        )
          descriptor = authority.descriptor
          ended_at = [ utc_time(@clock.call), started_at ].max
          result = QualificationLaneResult.build(
            run_id: descriptor.run_id,
            lane: lane,
            status: failure.status,
            started_at: started_at,
            ended_at: ended_at,
            target_sha256: authority.target_sha256,
            exit_code: failure.exit_code,
            failure_reason: failure.reason
          )
          repro_json = repro_json(
            descriptor,
            lane: lane,
            target_sha256: authority.target_sha256
          )
          repro_script = repro_script(descriptor, lane: lane)
          artifacts = {
            "failure.json" =>
              canonical(
                "schema" =>
                  "hive-patrol-qualification-failure",
                "schema_version" => 1,
                "run_id" => descriptor.run_id,
                "lane" => lane,
                "status" => failure.status,
                "reason" => failure.reason,
                "exit_code" => failure.exit_code
              ),
            "process-results.json" =>
              canonical(
                "schema" => PROCESS_SCHEMA,
                "schema_version" => 1,
                "run_id" => descriptor.run_id,
                "lane" => lane,
                "processes" => process_rows
              ),
            "scenario-manifest.json" =>
              authority.scenario_manifest_bytes
          }.merge(
            provider_artifacts(provider_brokers)
          ).freeze
          digests = artifact_digests(
            result: result,
            artifacts: artifacts,
            repro_json: repro_json,
            repro_script: repro_script
          )
          effect_index = PatrolEffectIndex.build(records: [])
          receipt = PatrolEvidenceReceipt.build(
            run_id: descriptor.run_id,
            lane: lane,
            lane_result: "failed",
            failure_reason: failure.reason,
            candidate: descriptor.candidate,
            control: descriptor.control,
            configuration_digests:
              configuration_digests(descriptor),
            project: descriptor.project,
            module_selections: descriptor.module_selections,
            scenario_manifest_digest:
              descriptor.scenarios.fetch("manifest_sha256"),
            decision_refs: [],
            matrix:
              descriptor.expectations.fetch("required_matrix"),
            faults:
              descriptor.expectations.fetch("required_faults"),
            restart_count: 0,
            effect_index_digest: effect_index.digest,
            expected_legacy_effect_keys:
              descriptor.expectations.fetch(
                "expected_legacy_effect_keys"
              ),
            artifact_digests: digests,
            reviewer: REVIEWER,
            generated_at: ended_at,
            reviewed_at: ended_at,
            observed_started_at: started_at,
            observed_ended_at: ended_at
          )
          {
            result: result,
            bundle: canonical(
              "receipt" => receipt.to_h,
              "records" => []
            ),
            artifacts: artifacts,
            repro_json: repro_json,
            repro_script: repro_script
          }.freeze
        end

        def receipt_decisions(descriptor, observations)
          expected = descriptor.expectations
            .fetch("decision_expectations")
            .to_h do |row|
              [ row.fetch("decision_id"), row ]
            end
          observations.observations.map do |row|
            expected.fetch(
              row.fetch("decision_id")
            ).merge(
              "record_digest" =>
                row.fetch("comparator_semantic_digest")
            )
          end.sort_by do |row|
            row.fetch("decision_id")
          end.freeze
        end

        def resolved_bindings(descriptor, lane:, artifact_digests:)
          bindings = descriptor.authority_for(lane).merge(
            "artifact_digests" => artifact_digests,
            "configuration_digests" =>
              configuration_digests(descriptor)
          ).freeze
          LiveBindingsResolver::Result.new(
            status: "resolved",
            bindings: bindings,
            issues: [].freeze
          ).freeze
        end

        def configuration_digests(descriptor)
          descriptor.module_selections.to_h do |name, selection|
            [
              name,
              selection.dig(
                "active",
                "configuration_digest"
              )
            ]
          end.freeze
        end

        def artifact_digests(
          result:, artifacts:, repro_json:, repro_script:
        )
          values = {
            "result" =>
              Digest::SHA256.hexdigest(
                QualificationLaneResult.canonical(result.to_h)
              ),
            "repro_json" => Digest::SHA256.hexdigest(repro_json),
            "repro_script" =>
              Digest::SHA256.hexdigest(repro_script)
          }
          artifacts.keys.sort.each do |name|
            key = "artifact.#{name.tr('/', '.')}"
            values[key] =
              Digest::SHA256.hexdigest(artifacts.fetch(name))
          end
          values.keys.sort.to_h do |key|
            [ key.freeze, values.fetch(key).freeze ]
          end.freeze
        end

        def process_projection(case_id, generation)
          generation.receipt.process.merge(
            "kind" => "result",
            "case_id" => case_id,
            "generation" => generation.generation,
            "planned_checkpoint" =>
              generation.planned_checkpoint,
            "generation_receipt_sha256" =>
              generation.receipt.sha256
          ).freeze
        rescue NoMethodError, KeyError
          raise Hive::ConfigError,
                "patrol qualification process result is malformed"
        end

        def raw_process_projection(
          case_id,
          generation:,
          planned_checkpoint:,
          process:
        )
          if process.is_a?(
            QualificationScenarioProcess::FailureEvidence
          )
            return {
              "kind" => "post_spawn_failure",
              "case_id" => case_id,
              "generation" => generation,
              "planned_checkpoint" => planned_checkpoint,
              "generation_receipt_sha256" => nil,
              "failure" => process.to_h
            }.freeze
          end

          QualificationScenarioOrchestrator::PROCESS_KEYS.to_h do |key|
            [ key, process.public_send(key) ]
          end.merge(
            "kind" => "result",
            "case_id" => case_id,
            "generation" => generation,
            "planned_checkpoint" => planned_checkpoint,
            "generation_receipt_sha256" => nil
          ).freeze
        rescue NoMethodError
          raise Hive::ConfigError,
                "patrol qualification process result is malformed"
        end

        def repro_json(descriptor, lane:, target_sha256:)
          canonical(
            "schema" => REPRO_SCHEMA,
            "schema_version" => 1,
            "run_id" => descriptor.run_id,
            "lane" => lane,
            "target_sha256" => target_sha256,
            "command" => replay_argv(descriptor, lane: lane)
          )
        end

        def repro_script(descriptor, lane:)
          command = replay_argv(descriptor, lane: lane)
            .map { |value| Shellwords.escape(value) }
            .join(" ")
          <<~SH
            #!/usr/bin/env bash
            set -euo pipefail
            : "${HIVE_HOME:?HIVE_HOME must select the imported run}"
            exec ${HIVE_BIN:-hive} #{command}
          SH
        end

        def replay_argv(descriptor, lane:)
          [
            "module", "migration", "qualify",
            "--run-id", descriptor.run_id,
            "--lane", lane
          ].freeze
        end

        def publish_completed(authority, lane:, completed:)
          @repository.publish_qualification_lane(
            run_id: authority.descriptor.run_id,
            lane: lane,
            result_bytes:
              QualificationLaneResult.canonical(
                completed.fetch(:result).to_h
              ),
            bundle_bytes: completed.fetch(:bundle),
            artifacts: completed.fetch(:artifacts),
            repro_json: completed.fetch(:repro_json),
            repro_script: completed.fetch(:repro_script)
          )
          completed.fetch(:result)
        end

        def publish_blocked(
          authority, lane:, started_at:, reason:
        )
          result = QualificationLaneResult.build(
            run_id: authority.descriptor.run_id,
            lane: lane,
            status: "blocked",
            started_at: started_at,
            ended_at: [ utc_time(@clock.call), started_at ].max,
            target_sha256: authority.target_sha256,
            failure_reason: reason
          )
          @repository.publish_qualification_lane_diagnostic(
            run_id: result.run_id,
            lane: result.lane,
            result_bytes:
              QualificationLaneResult.canonical(result.to_h)
          )
          result
        end

        def publish_failure(
          authority, lane:, started_at:, failure:
        )
          raise failure unless authority && started_at

          result = QualificationLaneResult.build(
            run_id: authority.descriptor.run_id,
            lane: lane,
            status: failure.status,
            started_at: started_at,
            ended_at: [ utc_time(@clock.call), started_at ].max,
            target_sha256: authority.target_sha256,
            exit_code: failure.exit_code,
            failure_reason: failure.reason
          )
          publish_result(result)
        end

        def publish_result(result)
          @repository.publish_qualification_lane_result(
            run_id: result.run_id,
            lane: result.lane,
            result_bytes:
              QualificationLaneResult.canonical(result.to_h)
          )
          result
        end

        def load_authority(run_id, lane)
          descriptor = QualificationRunDescriptor.load(
            @repository.qualification_descriptor(run_id)
          )
          unless descriptor.run_id == run_id
            raise Hive::ConfigError,
                  "patrol qualification run descriptor does not match run"
          end
          policy = descriptor.lane_policy(lane)
          source_ref =
            descriptor
              .lane_policy("deterministic")
              .fetch("target_ref")
          source = input_snapshot(run_id, source_ref)
          source_sha256 = verify_deterministic_target!(
            descriptor,
            source.fetch(:bytes)
          )
          installed_sha256, installed_files =
            verify_installed_target!(
              descriptor,
              run_id,
              descriptor
                .lane_policy("installed")
                .fetch("target_ref")
            )
          manifest, scenarios =
            load_scenarios(run_id, descriptor)
          target_sha256 =
            policy.fetch("kind") == "source_archive" ?
              source_sha256 : installed_sha256
          Authority.new(
            descriptor: descriptor,
            target_sha256: target_sha256,
            source_bytes: source.fetch(:bytes),
            installed_files: installed_files,
            scenario_manifest_bytes: manifest,
            scenarios: scenarios
          ).freeze
        rescue KeyError
          raise Hive::ConfigError,
                "patrol qualification lane target is malformed"
        end

        def input_snapshot(run_id, ref)
          value = @repository.qualification_input_snapshot(
            run_id, ref, missing: true
          )
          unless value && value.fetch(:mode) == 0o600
            raise Hive::ConfigError,
                  "patrol qualification lane input is missing or unsafe"
          end
          value
        rescue KeyError
          raise Hive::ConfigError,
                "patrol qualification lane input is missing or unsafe"
        end

        def verify_deterministic_target!(descriptor, bytes)
          actual = Digest::SHA256.hexdigest(bytes)
          expected =
            descriptor.candidate.fetch(
              "source_archive_sha256"
            )
          unless actual == expected
            raise Hive::ConfigError,
                  "patrol qualification lane target digest changed"
          end
          actual.freeze
        end

        def verify_installed_target!(
          descriptor, run_id, target_ref
        )
          files = {}
          walk_installed_target(
            run_id,
            "inputs/installed-target",
            files,
            depth: 0
          )
          target = files[target_ref]
          unless target && target.fetch(:mode) == 0o600
            raise Hive::ConfigError,
                  "patrol qualification lane target is missing or unsafe"
          end
          actual = installed_tree_digest(files)
          expected =
            descriptor.candidate.fetch(
              "installed_tree_sha256"
            )
          unless actual == expected
            raise Hive::ConfigError,
                  "patrol qualification lane target digest changed"
          end
          [ actual.freeze, files.freeze ].freeze
        end

        def load_scenarios(run_id, descriptor)
          scenarios = descriptor.scenarios
          manifest = input_snapshot(
            run_id,
            scenarios.fetch("manifest_ref")
          ).fetch(:bytes)
          unless
            Digest::SHA256.hexdigest(manifest) ==
              scenarios.fetch("manifest_sha256")
            raise Hive::ConfigError,
                  "patrol qualification scenario manifest changed"
          end
          rows = scenarios.fetch("cases").map do |row|
            snapshot = input_snapshot(
              run_id,
              row.fetch("scenario_ref")
            )
            bytes = snapshot.fetch(:bytes)
            unless
              Digest::SHA256.hexdigest(bytes) ==
                row.fetch("scenario_sha256")
              raise Hive::ConfigError,
                    "patrol qualification scenario input changed"
            end
            {
              case_id: row.fetch("case_id"),
              scenario_ref: row.fetch("scenario_ref"),
              scenario_sha256:
                row.fetch("scenario_sha256"),
              bytes: bytes
            }.freeze
          end
          [ manifest, rows.freeze ].freeze
        end

        def walk_installed_target(run_id, relative, files, depth:)
          if depth > MAX_INSTALLED_DEPTH
            raise Hive::ConfigError,
                  "patrol qualification installed target is too deep"
          end
          children =
            @repository.each_qualification_input_child(
              run_id, relative
            ).to_a
          children.sort.each do |name|
            child = "#{relative}/#{name}"
            type =
              @repository.qualification_input_entry_type(
                run_id, child
              )
            if type == :directory
              walk_installed_target(
                run_id, child, files, depth: depth + 1
              )
              next
            end
            if files.size >= MAX_INSTALLED_FILES
              raise Hive::ConfigError,
                    "patrol qualification installed target has too many files"
            end
            files[child] =
              @repository.qualification_input_snapshot(
                run_id, child
              )
          end
        end

        def installed_tree_digest(files)
          value = Digest::SHA256.new
          value << "hive-installed-tree-v1\0"
          files.keys.sort.each do |ref|
            snapshot = files.fetch(ref)
            relative =
              ref.delete_prefix(
                "inputs/installed-target/"
              )
            bytes = snapshot.fetch(:bytes)
            value << relative << "\0"
            value << snapshot.fetch(:mode).to_s(8) << "\0"
            value << bytes.bytesize.to_s << "\0"
            value << Digest::SHA256.hexdigest(bytes) << "\0"
          end
          value.hexdigest
        end

        def live_credential(policy)
          bindings = policy.fetch("credential_bindings")
          return nil unless
            bindings ==
              QualificationRunDescriptor::
                INSTALLED_CREDENTIAL_BINDINGS

          secret = @environment[bindings.fetch(0)].to_s
          secret.empty? ? nil : secret
        rescue KeyError, NoMethodError, TypeError
          nil
        end

        def load_existing(run_id, lane, target_sha256)
          bytes = @repository.qualification_lane_result(
            run_id, lane, missing: true
          )
          return unless bytes

          result = QualificationLaneResult.load(bytes)
          unless
            result.run_id == run_id &&
              result.lane == lane &&
              result.target_sha256 == target_sha256
            raise Hive::ConfigError,
                  "patrol qualification lane result authority changed"
          end
          result
        end

        def normalized_exit(value)
          code = Integer(value || 1)
          code.between?(1, 255) ? code : 1
        rescue ArgumentError, TypeError
          1
        end

        def utc_time(value)
          value.is_a?(Time) ?
            value.utc :
            Time.iso8601(value.to_s).utc
        rescue ArgumentError, TypeError
          raise Hive::ConfigError,
                "patrol qualification time is malformed"
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end
      end
    end
  end
end
