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
require "hive/modules/migration/qualification_lane_result"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/modules/migration/qualification_scenario_actuals"
require "hive/modules/migration/qualification_scenario_observations"
require "hive/modules/migration/qualification_scenario_oracle"
require "hive/modules/migration/qualification_scenario_process"
require "hive/modules/migration/qualification_scenario_request"
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
          :source_root, :installed_root, :executable
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
          oracle: QualificationScenarioOracle.new,
          verifier: PatrolEvidenceVerifier
        )
          @repository = repository
          @clock = clock
          @monotonic = monotonic
          @environment = environment
          @source_materializer = source_materializer
          @installed_materializer = installed_materializer
          @scenario_process = scenario_process
          @oracle = oracle
          @verifier = verifier
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

            credentials = live_credentials(
              descriptor.lane_policy(lane)
            )
            return publish_blocked(
              authority,
              lane: lane,
              started_at: started_at,
              reason: "credentials_unavailable"
            ) unless credentials

            # A live lane must use the declared provider and model policy.
            # Until that contract exists, never replay deterministic fixture
            # output under a live/installed label.
            return publish_blocked(
              authority,
              lane: lane,
              started_at: started_at,
              reason: "provider_unavailable"
            )
          end

          execute_lane(
            authority,
            lane: lane,
            started_at: started_at,
            credentials: {}
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

        def execute_lane(authority, lane:, started_at:, credentials:)
          descriptor = authority.descriptor
          policy = descriptor.lane_policy(lane)
          deadline =
            @monotonic.call + policy.fetch("timeout_seconds")
          completed = nil
          process_rows = []
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
                credentials: credentials,
                deadline: deadline,
                process_rows: process_rows
              )
              observations = @oracle.call(
                descriptor: descriptor,
                lane: lane,
                actuals: actuals
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
                process_rows: process_rows
              )
            rescue LaneFailure => failure
              completed = build_failed_capture(
                authority: authority,
                lane: lane,
                started_at: started_at,
                failure: failure,
                process_rows: process_rows
              )
            rescue Hive::ConfigError, KeyError, NoMethodError,
                   TypeError
              completed = build_failed_capture(
                authority: authority,
                lane: lane,
                started_at: started_at,
                failure: LaneFailure.new(
                  status: "failed",
                  reason: "evidence_verification_failed",
                  exit_code: 1
                ),
                process_rows: process_rows
              )
            rescue StandardError
              completed = build_failed_capture(
                authority: authority,
                lane: lane,
                started_at: started_at,
                failure: LaneFailure.new(
                  status: "failed",
                  reason: "internal_error",
                  exit_code: 1
                ),
                process_rows: process_rows
              )
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
          end
          directory.ensure_directory("requests")
          directory
        end

        def execute_scenarios(
          workspace:, directory:, materialized:, authority:,
          lane:, policy:, credentials:, deadline:, process_rows:
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
            request_ref = write_request(
              directory,
              authority.descriptor,
              row
            )
            case_root = File.join(
              workspace,
              "cases",
              row.fetch(:case_id)
            )
            hive_home = File.join(
              case_root,
              "sandbox",
              "hive-home"
            )
            process = @scenario_process.call(
              executable: materialized.executable,
              argv: [
                "__patrol-qualification-scenario",
                "--workspace", workspace,
                "--request", request_ref
              ],
              workspace: workspace,
              source_root: materialized.source_root,
              installed_root: materialized.installed_root,
              case_root: case_root,
              request_ref: request_ref,
              scenario_ref: row.fetch(:scenario_ref),
              timeout_seconds: [
                remaining,
                policy.fetch("timeout_seconds")
              ].min,
              network: policy.fetch("network"),
              credentials: credentials,
              hive_home: hive_home
            )
            process_rows << process_projection(
              row.fetch(:case_id),
              process
            )
            if process.timed_out
              raise LaneFailure.new(
                status: "timeout",
                reason: "lane_timeout"
              )
            end
            unless process.status == "passed" &&
                   process.exit_status == 0
              raise LaneFailure.new(
                status: "failed",
                reason: "candidate_execution_failed",
                exit_code: normalized_exit(process.exit_status)
              )
            end
            output_ref =
              "cases/#{row.fetch(:case_id)}/output/" \
              "scenario-actuals.json"
            actuals << QualificationScenarioActuals.load(
              directory.read(
                output_ref,
                max_bytes:
                  QualificationScenarioActuals::MAX_BYTES
              )
            )
          end
          actuals.freeze
        end

        def write_request(directory, descriptor, row)
          case_id = row.fetch(:case_id)
          value = {
            "schema" => QualificationScenarioRequest::SCHEMA,
            "schema_version" =>
              QualificationScenarioRequest::SCHEMA_VERSION,
            "case_id" => case_id,
            "scenario_sha256" => row.fetch(:scenario_sha256),
            "scenario_ref" => row.fetch(:scenario_ref),
            "package_root_ref" => "targets/source",
            "sandbox_root_ref" =>
              "cases/#{case_id}/sandbox",
            "output_ref" =>
              "cases/#{case_id}/output/scenario-actuals.json",
            "project" => descriptor.project
          }
          bytes = QualificationScenarioRequest.canonical(value)
          QualificationScenarioRequest.load(bytes)
          ref = "requests/#{case_id}.json"
          directory.atomic_write(
            ref,
            bytes,
            mode: 0o600,
            expected_absent: true
          )
          ref.freeze
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
          records:, process_rows:
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
          authority:, lane:, started_at:, failure:, process_rows:
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
          }.freeze
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

        def process_projection(case_id, process)
          {
            "case_id" => case_id,
            "status" => process.status,
            "exit_status" => process.exit_status,
            "signal" => process.signal,
            "timed_out" => process.timed_out,
            "network_isolated" => process.network_isolated,
            "stdout" => process.stdout,
            "stderr" => process.stderr,
            "duration_seconds" => process.duration_seconds,
            "executable_sha256" =>
              process.executable_sha256,
            "ruby_sha256" => process.ruby_sha256,
            "attempt_count" => process.attempt_count,
            "custody_count" => process.custody_count,
            "sandbox_profile_sha256" =>
              process.sandbox_profile_sha256,
            "source_inventory_sha256" =>
              process.source_inventory_sha256,
            "installed_inventory_sha256" =>
              process.installed_inventory_sha256,
            "teardown" => process.teardown
          }.freeze
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
          publish_result(result)
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

        def live_credentials(policy)
          policy.fetch("credential_bindings").to_h do |name|
            secret = @environment[name].to_s
            return nil if secret.empty?

            [ name, secret ]
          end.freeze
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
