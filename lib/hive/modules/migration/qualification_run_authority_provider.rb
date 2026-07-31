require "digest"
require "json"
require "time"
require "hive/errors"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/patrol_effect_index"
require "hive/modules/migration/qualification_lane_result"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/modules/migration/qualification_scenario_observations"
require "hive/modules/migration/shadow_comparator"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Reopens and verifies every descriptor-owned input and completed lane
      # artifact before exposing authority to report verification. Neither the
      # receipt nor its records may define the run's expected outcomes.
      class QualificationRunAuthorityProvider
        MANIFEST_SCHEMA =
          "hive-release-candidate-artifacts".freeze
        MANIFEST_KEYS = %w[
          builder_revision candidate_sha canonical_digest files
          hive_version schema schema_version skill_version
        ].freeze
        ARTIFACT_KINDS = %w[gem source skills web].freeze
        ARTIFACT_KEYS = %w[kind sha256 size].freeze
        TARGET_SCHEMA =
          "hive-release-candidate-installed-target".freeze
        TARGET_KEYS = %w[
          executable gem_sha256 role schema schema_version skills
          version
        ].freeze
        TARGET_SKILL_KEYS = %w[archive_sha256 import_root].freeze
        SCENARIO_MANIFEST_KEYS = %w[cases].freeze
        SCENARIO_ROW_KEYS = %w[case_id path sha256].freeze
        MAX_MANIFEST_BYTES = 4 * 1024 * 1024
        MAX_TARGET_BYTES = 1024 * 1024
        MAX_SCENARIO_BYTES = 16 * 1024 * 1024
        MAX_INSTALLED_FILES = 4_096
        MAX_INSTALLED_DEPTH = 32
        DIGEST = /\A[0-9a-f]{64}\z/
        SHA = /\A[0-9a-f]{40}\z/
        SAFE_FILE = /\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}\z/

        Outcome = Data.define(:status, :bindings, :issues) do
          def resolved? = status == "resolved"
          def blocked? = status == "blocked"
          def failed? = status == "failed"
        end

        class EvidenceProblem < StandardError
          attr_reader :issues

          def initialize(*issues)
            @issues =
              issues.flatten.map(&:to_s).uniq.sort.freeze
            super(@issues.first.to_s)
          end

          def code = issues.first
        end
        private_constant :EvidenceProblem

        class BlockedEvidence < EvidenceProblem; end
        private_constant :BlockedEvidence

        class FailedEvidence < EvidenceProblem; end
        private_constant :FailedEvidence

        def initialize(repository:)
          unless repository.respond_to?(:qualification_descriptor) &&
                 repository.respond_to?(:qualification_input) &&
                 repository.respond_to?(:qualification_lane_result) &&
                 repository.respond_to?(
                   :qualification_lane_diagnostics
                 ) &&
                 repository.respond_to?(:qualification_lane)
            raise Hive::ConfigError,
                  "patrol qualification repository is malformed"
          end

          @repository = repository
        end

        def call(run_id:, lane:)
          run_id = run_id.to_s
          lane = lane.to_s
          unless QualificationRunDescriptor::RUN_ID.match?(run_id) &&
                 QualificationRunDescriptor::LANES.include?(lane)
            return failed("qualification_request_malformed")
          end

          descriptor_bytes = read_descriptor(run_id)
          return blocked("qualification_descriptor_missing") unless
            descriptor_bytes

          descriptor = load_descriptor(descriptor_bytes)
          unless descriptor.run_id == run_id
            return failed("qualification_descriptor_run_mismatch")
          end

          candidate = verify_candidate(run_id, descriptor)
          verify_scenarios(run_id, descriptor)
          target_digest = verify_target(
            run_id, lane, descriptor, candidate
          )
          result_bytes = read_result(run_id, lane)
          result = verify_result(
            result_bytes,
            run_id: run_id,
            lane: lane,
            target_digest: target_digest,
            timeout_seconds:
              descriptor.lane_policy(lane).fetch("timeout_seconds")
          )
          lane_files = read_lane(run_id, lane)
          verify_capture(
            lane_files,
            run_id: run_id,
            lane: lane,
            descriptor: descriptor
          )
          unless lane_files.fetch("result.json") == result_bytes
            raise FailedEvidence,
                  "qualification_result_changed_during_capture"
          end
          bindings = descriptor.authority_for(lane).merge(
            "artifact_digests" =>
              artifact_digests(lane_files, result)
          ).freeze
          Outcome.new(
            status: "resolved",
            bindings: bindings,
            issues: [].freeze
          ).freeze
        rescue BlockedEvidence => error
          blocked(*error.issues)
        rescue FailedEvidence => error
          failed(*error.issues)
        rescue Hive::ConfigError
          failed("qualification_evidence_unsafe")
        rescue StandardError
          failed("qualification_evidence_unsafe")
        end

        private

        def read_descriptor(run_id)
          @repository.qualification_descriptor(
            run_id, missing: true
          )
        rescue Hive::ConfigError
          raise FailedEvidence,
                "qualification_descriptor_unsafe"
        end

        def load_descriptor(bytes)
          QualificationRunDescriptor.load(bytes)
        rescue Hive::ConfigError
          raise FailedEvidence,
                "qualification_descriptor_malformed"
        end

        def read_lane(run_id, lane)
          files = @repository.qualification_lane(
            run_id, lane, missing: true
          )
          unless files
            raise BlockedEvidence,
                  "qualification_lane_missing"
          end
          files
        rescue BlockedEvidence
          raise
        rescue Hive::ConfigError
          raise FailedEvidence,
                "qualification_capture_incomplete_or_unsafe"
        end

        def read_result(run_id, lane)
          bytes = @repository.qualification_lane_result(
            run_id, lane, missing: true
          )
          unless bytes
            diagnostics =
              @repository.qualification_lane_diagnostics(
                run_id,
                lane
              )
            latest = diagnostics.max_by do |result|
              [
                result.ended_at,
                result.started_at,
                result.failure_reason.to_s
              ]
            end
            if latest
              raise BlockedEvidence,
                    "qualification_lane_blocked:" \
                    "#{latest.failure_reason}"
            end
            raise BlockedEvidence,
                  "qualification_lane_missing"
          end
          bytes
        rescue BlockedEvidence
          raise
        rescue Hive::ConfigError
          raise FailedEvidence,
                "qualification_result_unsafe"
        end

        def verify_candidate(run_id, descriptor)
          manifest_snapshot = read_input_snapshot(
            run_id,
            "inputs/candidate/manifest.json",
            max_bytes: MAX_MANIFEST_BYTES,
            missing_code: "candidate_manifest_missing"
          )
          unless manifest_snapshot.fetch(:mode) == 0o600
            raise FailedEvidence,
                  "candidate_manifest_mode_mismatch"
          end
          manifest_bytes = manifest_snapshot.fetch(:bytes)
          descriptor_candidate = descriptor.candidate
          unless digest(manifest_bytes) ==
                 descriptor_candidate.fetch(
                   "artifact_manifest_sha256"
                 )
            raise FailedEvidence,
                  "candidate_manifest_digest_mismatch"
          end
          manifest = canonical_json(
            manifest_bytes, "candidate_manifest_malformed"
          )
          exact!(
            manifest, MANIFEST_KEYS,
            "candidate_manifest_malformed"
          )
          unless manifest["schema"] == MANIFEST_SCHEMA &&
                 manifest["schema_version"] == 1 &&
                 SHA.match?(manifest["candidate_sha"].to_s) &&
                 manifest["candidate_sha"] ==
                   descriptor_candidate.fetch("commit_sha") &&
                 nonempty?(manifest["hive_version"]) &&
                 nonempty?(manifest["skill_version"]) &&
                 DIGEST.match?(
                   manifest["canonical_digest"].to_s
                 ) &&
                 DIGEST.match?(
                   manifest["builder_revision"].to_s
                 )
            raise FailedEvidence,
                  "candidate_manifest_malformed"
          end

          files = manifest["files"]
          unless files.is_a?(Hash) &&
                 files.size == ARTIFACT_KINDS.size
            raise FailedEvidence,
                  "candidate_manifest_malformed"
          end
          kinds = {}
          files.keys.sort.each do |name|
            record = files.fetch(name)
            unless SAFE_FILE.match?(name.to_s)
              raise FailedEvidence,
                    "candidate_manifest_malformed"
            end
            exact!(
              record, ARTIFACT_KEYS,
              "candidate_manifest_malformed"
            )
            kind = record["kind"]
            unless ARTIFACT_KINDS.include?(kind) &&
                   !kinds.key?(kind) &&
                   DIGEST.match?(record["sha256"].to_s) &&
                   record["size"].is_a?(Integer) &&
                   record["size"] >= 0
              raise FailedEvidence,
                    "candidate_manifest_malformed"
            end
            snapshot = read_input_snapshot(
              run_id,
              "inputs/candidate/#{name}",
              max_bytes: [
                record.fetch("size"),
                MigrationRepository::MAX_QUALIFICATION_INPUT_BYTES
              ].min,
              missing_code: "candidate_artifact_missing:#{kind}"
            )
            unless snapshot.fetch(:mode) == 0o600 &&
                   snapshot.fetch(:bytes).bytesize ==
                     record["size"] &&
                   digest(snapshot.fetch(:bytes)) ==
                     record["sha256"]
              raise FailedEvidence,
                    "candidate_artifact_digest_mismatch"
            end
            kinds[kind] = {
              "name" => name,
              "sha256" => record.fetch("sha256")
            }.freeze
          end
          unless kinds.keys.sort == ARTIFACT_KINDS.sort
            raise FailedEvidence,
                  "candidate_manifest_malformed"
          end
          verify_exact_children(
            run_id,
            "inputs/candidate",
            [ "manifest.json", *files.keys ],
            failure_code: "candidate_artifact_substitution"
          )

          expected = {
            "source" => "source_archive_sha256",
            "gem" => "candidate_gem_sha256",
            "skills" => "skills_archive_sha256"
          }
          expected.each do |kind, descriptor_key|
            unless kinds.fetch(kind).fetch("sha256") ==
                   descriptor_candidate.fetch(descriptor_key)
              raise FailedEvidence,
                    "candidate_artifact_digest_mismatch"
            end
          end
          kinds.freeze
        end

        def verify_scenarios(run_id, descriptor)
          scenarios = descriptor.scenarios
          manifest_ref = scenarios.fetch("manifest_ref")
          manifest_snapshot = read_input_snapshot(
            run_id,
            manifest_ref,
            max_bytes: MAX_MANIFEST_BYTES,
            missing_code: "scenario_manifest_missing"
          )
          unless manifest_snapshot.fetch(:mode) == 0o600
            raise FailedEvidence,
                  "scenario_input_mode_mismatch"
          end
          manifest_bytes = manifest_snapshot.fetch(:bytes)
          unless digest(manifest_bytes) ==
                 scenarios.fetch("manifest_sha256")
            raise FailedEvidence,
                  "scenario_manifest_digest_mismatch"
          end
          manifest = canonical_json(
            manifest_bytes, "scenario_manifest_malformed"
          )
          exact!(
            manifest, SCENARIO_MANIFEST_KEYS,
            "scenario_manifest_malformed"
          )
          rows = manifest["cases"]
          unless rows.is_a?(Array) && !rows.empty?
            raise FailedEvidence,
                  "scenario_manifest_malformed"
          end
          expected = scenarios.fetch("cases").to_h do |row|
            [
              row.fetch("case_id"),
              {
                "case_id" => row.fetch("case_id"),
                "path" => row.fetch("scenario_ref"),
                "sha256" => row.fetch("scenario_sha256")
              }
            ]
          end
          actual = rows.to_h do |row|
            exact!(
              row, SCENARIO_ROW_KEYS,
              "scenario_manifest_malformed"
            )
            case_id = row["case_id"]
            unless nonempty?(case_id) &&
                   nonempty?(row["path"]) &&
                   DIGEST.match?(row["sha256"].to_s)
              raise FailedEvidence,
                    "scenario_manifest_malformed"
            end
            [ case_id, row ]
          end
          unless actual.size == rows.size && actual == expected
            raise FailedEvidence,
                  "scenario_manifest_descriptor_mismatch"
          end
          rows.each do |row|
            snapshot = read_input_snapshot(
              run_id,
              row.fetch("path"),
              max_bytes: MAX_SCENARIO_BYTES,
              missing_code:
                "scenario_case_missing:#{row.fetch('case_id')}"
            )
            unless snapshot.fetch(:mode) == 0o600
              raise FailedEvidence,
                    "scenario_input_mode_mismatch"
            end
            unless digest(snapshot.fetch(:bytes)) ==
                   row.fetch("sha256")
              raise FailedEvidence,
                    "scenario_case_digest_mismatch"
            end
          end
          verify_exact_input_tree(
            run_id,
            "inputs/scenarios",
            [
              manifest_ref,
              *rows.map { |row| row.fetch("path") }
            ],
            failure_code: "scenario_input_substitution"
          )
          true
        rescue ArgumentError, KeyError, NoMethodError, TypeError
          raise FailedEvidence,
                "scenario_manifest_malformed"
        end

        def verify_target(run_id, lane, descriptor, candidate)
          policy = descriptor.lane_policy(lane)
          if lane == "deterministic"
            source = candidate.fetch("source")
            unless policy.fetch("target_ref") ==
                   "inputs/candidate/#{source.fetch('name')}"
              raise FailedEvidence,
                    "qualification_target_substitution"
            end
            return source.fetch("sha256")
          end

          verify_installed_target(run_id, descriptor, policy)
        end

        def verify_installed_target(run_id, descriptor, policy)
          files = installed_files(run_id)
          target = files[policy.fetch("target_ref")]
          unless target
            raise BlockedEvidence,
                  "installed_target_missing"
          end
          target_payload = canonical_json(
            target.fetch(:bytes),
            "installed_target_manifest_malformed"
          )
          exact!(
            target_payload, TARGET_KEYS,
            "installed_target_manifest_malformed"
          )
          skills = target_payload["skills"]
          exact!(
            skills, TARGET_SKILL_KEYS,
            "installed_target_manifest_malformed"
          )
          unless target_payload["schema"] == TARGET_SCHEMA &&
                 target_payload["schema_version"] == 1 &&
                 target_payload["role"] == "candidate" &&
                 nonempty?(target_payload["version"]) &&
                 DIGEST.match?(
                   target_payload["gem_sha256"].to_s
                 ) &&
                 DIGEST.match?(
                   skills["archive_sha256"].to_s
                 ) &&
                 safe_relative?(skills["import_root"]) &&
                 target_payload["executable"] ==
                   policy.fetch("executable") &&
                 safe_relative?(
                   target_payload["executable"]
                 )
            raise FailedEvidence,
                  "installed_target_manifest_malformed"
          end
          candidate = descriptor.candidate
          unless target_payload["gem_sha256"] ==
                   candidate.fetch("candidate_gem_sha256") &&
                 skills["archive_sha256"] ==
                   candidate.fetch("skills_archive_sha256")
            raise FailedEvidence,
                  "installed_target_candidate_mismatch"
          end
          executable_ref =
            "inputs/installed-target/" \
            "#{target_payload.fetch('executable')}"
          executable = files[executable_ref]
          unless executable
            raise BlockedEvidence,
                  "installed_target_executable_missing"
          end
          unless executable.fetch(:mode) == 0o700
            raise FailedEvidence,
                  "installed_target_executable_unsafe"
          end
          files.each do |ref, snapshot|
            expected_mode =
              ref == executable_ref ? 0o700 : 0o600
            unless snapshot.fetch(:mode) == expected_mode
              raise FailedEvidence,
                    "installed_target_file_mode_mismatch"
            end
          end

          tree_digest = installed_tree_digest(files)
          unless tree_digest ==
                 candidate.fetch("installed_tree_sha256")
            raise FailedEvidence,
                  "installed_target_digest_mismatch"
          end
          tree_digest
        rescue ArgumentError, KeyError, NoMethodError, TypeError
          raise FailedEvidence,
                "installed_target_manifest_malformed"
        end

        def installed_files(run_id)
          root = "inputs/installed-target"
          files = {}
          walk_installed_target(
            run_id, root, files, depth: 0
          )
          if files.empty?
            raise BlockedEvidence,
                  "installed_target_missing"
          end
          files.freeze
        end

        def walk_installed_target(run_id, relative, files, depth:)
          if depth > MAX_INSTALLED_DEPTH
            raise FailedEvidence,
                  "installed_target_exceeds_bounded_depth"
          end
          children = begin
            @repository.each_qualification_input_child(
              run_id, relative
            )&.to_a
          rescue Hive::ConfigError
            raise FailedEvidence,
                  "qualification_input_unsafe"
          end
          if children.nil?
            raise BlockedEvidence,
                  "installed_target_missing"
          end
          children.sort.each do |name|
            child = "#{relative}/#{name}"
            type = begin
              @repository.qualification_input_entry_type(
                run_id, child
              )
            rescue Hive::ConfigError
              raise FailedEvidence,
                    "qualification_input_unsafe"
            end
            if type == :directory
              walk_installed_target(
                run_id, child, files, depth: depth + 1
              )
              next
            end
            if files.size >= MAX_INSTALLED_FILES
              raise FailedEvidence,
                    "installed_target_exceeds_bounded_file_count"
            end
            files[child] = read_input_snapshot(
              run_id, child,
              max_bytes:
                MigrationRepository::MAX_QUALIFICATION_INPUT_BYTES,
              missing_code: "installed_target_file_missing"
            )
          end
        end

        def installed_tree_digest(files)
          value = Digest::SHA256.new
          value << "hive-installed-tree-v1\0"
          files.keys.sort.each do |ref|
            snapshot = files.fetch(ref)
            relative = ref.delete_prefix(
              "inputs/installed-target/"
            )
            bytes = snapshot.fetch(:bytes)
            value << relative << "\0"
            value << snapshot.fetch(:mode).to_s(8) << "\0"
            value << bytes.bytesize.to_s << "\0"
            value << digest(bytes) << "\0"
          end
          value.hexdigest
        end

        def verify_result(bytes, run_id:, lane:, target_digest:,
                          timeout_seconds:)
          result = QualificationLaneResult.load(bytes)
          unless result.run_id == run_id
            raise FailedEvidence,
                  "qualification_result_run_mismatch"
          end
          unless result.lane == lane
            raise FailedEvidence,
                  "qualification_result_lane_mismatch"
          end
          if result.duration_seconds > Integer(timeout_seconds)
            raise FailedEvidence,
                  "qualification_result_timeout"
          end
          unless result.target_sha256 == target_digest
            raise FailedEvidence,
                  "qualification_target_digest_mismatch"
          end
          case result.status
          when "passed"
          when "blocked"
            raise BlockedEvidence,
                  "qualification_lane_blocked:" \
                  "#{result.failure_reason}"
          when "failed"
            raise FailedEvidence,
                  "qualification_lane_failed:" \
                  "#{result.failure_reason}"
          when "timeout"
            raise FailedEvidence,
                  "qualification_result_timeout"
          end
          result
        rescue Hive::ConfigError
          raise FailedEvidence,
                "qualification_result_malformed"
        end

        def verify_capture(files, run_id:, lane:, descriptor:)
          unless files.is_a?(Hash) &&
                 files.key?("bundle.json") &&
                 files.key?("repro.json") &&
                 files.key?("repro.sh") &&
                 files.keys.any? do |key|
                   key.start_with?("artifacts/")
                 end
            raise FailedEvidence,
                  "qualification_capture_incomplete"
          end
          observations = load_scenario_observations(
            files,
            run_id: run_id,
            lane: lane,
            descriptor: descriptor
          )
          bundle = canonical_json(
            files.fetch("bundle.json"),
            "qualification_capture_malformed"
          )
          exact!(
            bundle, %w[receipt records],
            "qualification_capture_malformed"
          )
          unless bundle["receipt"].is_a?(Hash) &&
                 bundle["records"].is_a?(Array)
            raise FailedEvidence,
                  "qualification_capture_malformed"
          end
          repro = canonical_json(
            files.fetch("repro.json"),
            "qualification_capture_malformed"
          )
          unless repro.is_a?(Hash) &&
                 repro["run_id"] == run_id &&
                 repro["lane"] == lane
            raise FailedEvidence,
                  "qualification_capture_malformed"
          end
          script = files.fetch("repro.sh")
          unless script.is_a?(String) &&
                 script.start_with?("#!/") &&
                 script.end_with?("\n")
            raise FailedEvidence,
                  "qualification_capture_malformed"
          end
          verify_observation_membership(
            observations,
            descriptor: descriptor
          )
          verify_observation_evidence(
            observations,
            records: bundle.fetch("records"),
            descriptor: descriptor
          )
          true
        end

        def load_scenario_observations(files, run_id:, lane:,
                                       descriptor:)
          bytes =
            files["artifacts/scenario-observations.json"]
          unless bytes
            raise FailedEvidence,
                  "qualification_scenario_observations_missing"
          end
          observations =
            QualificationScenarioObservations.load(bytes)
          unless observations.run_id == run_id &&
                 observations.lane == lane &&
                 observations.scenario_manifest_sha256 ==
                   descriptor.scenarios.fetch("manifest_sha256")
            raise FailedEvidence,
                  "qualification_scenario_observations_authority_mismatch"
          end
          observations
        rescue Hive::ConfigError
          raise FailedEvidence,
                "qualification_scenario_observations_malformed"
        end

        def verify_observation_membership(observations,
                                          descriptor:)
          expected = descriptor.scenarios.fetch("cases").flat_map do |row|
            row.fetch("decision_expectations").map do |decision|
              [
                row.fetch("case_id"),
                decision.fetch("decision_id")
              ]
            end
          end.sort
          actual = observations.observations.map do |row|
            [
              row.fetch("case_id"),
              row.fetch("decision_id")
            ]
          end.sort
          unless (actual - expected).empty?
            raise FailedEvidence,
                  "qualification_scenario_observation_unknown"
          end
          unless (expected - actual).empty?
            raise FailedEvidence,
                  "qualification_scenario_observation_missing"
          end
        end

        def verify_observation_evidence(observations, records:,
                                        descriptor:)
          expectations = descriptor.scenarios.fetch("cases").to_h do |row|
            decisions = row.fetch("decision_expectations").to_h do |decision|
              [ decision.fetch("decision_id"), decision ]
            end
            [ row.fetch("case_id"), decisions ]
          end
          records_by_id =
            validated_observation_records(
              records,
              expected_ids:
                observations.observations.map do |row|
                  row.fetch("decision_id")
                end.uniq.sort
            )
          observations.observations.each do |row|
            expected = expectations
              .fetch(row.fetch("case_id"))
              .fetch(row.fetch("decision_id"))
            verify_descriptor_observation!(row, expected)
            verify_selection_observation!(
              row,
              descriptor: descriptor
            )
            record =
              records_by_id.fetch(row.fetch("decision_id"))
            verify_comparator_observation!(
              row,
              record,
              descriptor: descriptor
            )
          end
          verify_observation_coverage!(
            observations,
            descriptor: descriptor
          )
        rescue KeyError
          raise FailedEvidence,
                "qualification_scenario_observation_unknown"
        end

        def validated_observation_records(records, expected_ids:)
          unless records.is_a?(Array) &&
                 records.length <=
                   ShadowComparator::MAX_RECORDS
            raise FailedEvidence,
                  "qualification_scenario_observation_record_unbound"
          end
          validator = ShadowComparator.new(root: Dir.pwd)
          values = records.map do |value|
            validator.validate_record!(value)
          end
          ids = values.map { |record| record.fetch("decision_id") }
          unless ids.uniq.length == ids.length &&
                 ids.sort == expected_ids
            raise FailedEvidence,
                  "qualification_scenario_observation_record_unbound"
          end
          values.to_h do |record|
            [ record.fetch("decision_id"), record ]
          end
        rescue Hive::ConfigError, KeyError, NoMethodError, TypeError
          raise FailedEvidence,
                "qualification_scenario_observation_record_unbound"
        end

        def verify_descriptor_observation!(row, expected)
          fields = %w[
            decision_class decision_id module repository_sha
            trigger_digest
          ]
          unless fields.all? do |key|
                   row.fetch(key) == expected.fetch(key)
                 end
            raise FailedEvidence,
                  "qualification_scenario_observation_descriptor_mismatch"
          end
        end

        def verify_comparator_observation!(row, record,
                                           descriptor:)
          unless record["decision_id"] == row["decision_id"] &&
                 record["module"] == row["module"] &&
                 record["trigger_digest"] ==
                   row["trigger_digest"] &&
                 record["configuration_digest"] ==
                   descriptor.module_selections
                     .dig(
                       row.fetch("module"),
                       "active",
                       "configuration_digest"
                     ) &&
                 record["comparable"] == true &&
                 record["evidence_source"] ==
                   "legacy_mutator_capture" &&
                 record["migration"].nil?
            raise FailedEvidence,
                  "qualification_scenario_observation_comparator_mismatch"
          end
          verify_capture_observation!(
            row, record, descriptor: descriptor
          )
          unless record["semantic_digest"] ==
                 row["comparator_semantic_digest"]
            raise FailedEvidence,
                  "qualification_scenario_observation_comparator_mismatch"
          end
          verify_effect_observation!(row, record)
        end

        def verify_selection_observation!(row, descriptor:)
          selection =
            descriptor.module_selections.fetch(
              row.fetch("module")
            )
          epoch = selection.fetch("selection_epoch")
          active = selection.fetch("active")
          source_commit = active.fetch("source_commit")
          configuration_digest =
            active.fetch("configuration_digest")
          expected_ownership =
            "#{epoch}:#{source_commit}"
          decisions = row.fetch("decisions")
          attempts = row.fetch("attempts")
          valid =
            decisions.all? do |decision|
              decision["module_generation"] == source_commit &&
                decision["configuration_digest"] ==
                  configuration_digest
            end &&
            attempts.all? do |attempt|
              subject = attempt.fetch("subject")
              subject["module_generation"] == source_commit &&
                subject["configuration_digest"] ==
                  configuration_digest &&
                attempt["ownership_generation"] ==
                  expected_ownership &&
                attempt["task_input_epoch"] == epoch
            end
          unless valid
            raise FailedEvidence,
                  "qualification_scenario_observation_selection_mismatch"
          end
        rescue KeyError, NoMethodError, TypeError
          raise FailedEvidence,
                "qualification_scenario_observation_selection_mismatch"
        end

        def verify_observation_coverage!(observations, descriptor:)
          rows_by_case =
            observations.observations.group_by do |row|
              row.fetch("case_id")
          end
          observed_faults = []
          observed_effects = []
          observed_matrix = []
          descriptor.scenarios.fetch("cases").each do |case_row|
            rows = rows_by_case.fetch(case_row.fetch("case_id"))
            faults = rows.filter_map do |row|
              row["fault_checkpoint"]
            end.uniq.sort
            unless faults == case_row.fetch("faults")
              raise FailedEvidence,
                    "qualification_scenario_fault_coverage_mismatch"
            end
            effects = rows.flat_map do |row|
              row.fetch("legacy_effect_keys")
            end.uniq.sort
            unless effects ==
                   case_row.fetch("expected_legacy_effect_keys")
              raise FailedEvidence,
                    "qualification_scenario_observation_effect_mismatch"
            end
            matrix = rows.map do |row|
              row.fetch("decision_class")
            end.uniq.sort
            unless matrix == case_row.fetch("matrix")
              raise FailedEvidence,
                    "qualification_scenario_matrix_coverage_mismatch"
            end
            observed_faults.concat(faults)
            observed_effects.concat(effects)
            observed_matrix.concat(matrix)
          end
          unless observed_faults.uniq.sort ==
                 descriptor.expectations.fetch("required_faults")
            raise FailedEvidence,
                  "qualification_scenario_fault_coverage_mismatch"
          end
          unless observed_matrix.uniq.sort ==
                 descriptor.expectations.fetch("required_matrix")
            raise FailedEvidence,
                  "qualification_scenario_matrix_coverage_mismatch"
          end
          unless observed_effects.uniq.sort ==
                 descriptor.expectations.fetch(
                   "expected_legacy_effect_keys"
                 )
            raise FailedEvidence,
                  "qualification_scenario_observation_effect_mismatch"
          end
        rescue KeyError, NoMethodError, TypeError
          raise FailedEvidence,
                "qualification_scenario_observation_missing"
        end

        def verify_capture_observation!(row, record, descriptor:)
          record_capture = record.fetch("legacy_capture")
          event_capture =
            row.dig(
              "event",
              "payload",
              "legacy_mutator_capture"
            )
          project = descriptor.project
          unless record_capture.is_a?(Hash) &&
                 QualificationScenarioObservations.canonical(
                   record_capture
                 ) ==
                   QualificationScenarioObservations.canonical(
                     event_capture
                   ) &&
                 record_capture["capture_id"] ==
                   row["legacy_capture_id"] &&
                 record_capture["occurred_at"] ==
                   record["occurred_at"] &&
                 record_capture["project"] == project &&
                 row.dig("event", "project_id") ==
                   project.fetch("project_id") &&
                 row.dig("event", "project") ==
                   project.fetch("name")
            raise FailedEvidence,
                  "qualification_scenario_observation_capture_mismatch"
          end
        rescue KeyError, NoMethodError, TypeError
          raise FailedEvidence,
                "qualification_scenario_observation_capture_mismatch"
        end

        def verify_effect_observation!(row, record)
          index = PatrolEffectIndex.build(records: [ record ])
          module_keys = index.entries
            .select { |entry| entry["channel"] == "module" }
            .map { |entry| entry.fetch("effect_key") }
            .sort
          unless row["legacy_effect_keys"] ==
                   index.legacy_keys &&
                 row["module_effect_keys"] == module_keys
            raise FailedEvidence,
                  "qualification_scenario_observation_effect_mismatch"
          end
        rescue Hive::ConfigError, KeyError, NoMethodError, TypeError
          raise FailedEvidence,
                "qualification_scenario_observation_effect_mismatch"
        end

        def artifact_digests(files, result)
          values = {
            "result" => digest(
              QualificationLaneResult.canonical(result.to_h)
            ),
            "repro_json" => digest(files.fetch("repro.json")),
            "repro_script" => digest(files.fetch("repro.sh"))
          }
          files.keys.grep(/\Aartifacts\//).sort.each do |key|
            name = "artifact.#{key.delete_prefix('artifacts/').tr('/', '.')}"
            unless name.match?(/\A[a-z0-9][a-z0-9_.-]*\z/) &&
                   !values.key?(name)
              raise FailedEvidence,
                    "qualification_artifact_name_malformed"
            end
            values[name] = digest(files.fetch(key))
          end
          values.keys.sort.to_h do |key|
            [ key.freeze, values.fetch(key).freeze ]
          end.freeze
        end

        def verify_exact_children(run_id, root, expected,
                                  failure_code:)
          actual = begin
            @repository.each_qualification_input_child(
              run_id, root
            )&.to_a
          rescue Hive::ConfigError
            raise FailedEvidence,
                  "qualification_input_unsafe"
          end
          unless actual && actual.sort == expected.sort
            raise FailedEvidence, failure_code
          end
        end

        def verify_exact_input_tree(run_id, root, expected_files,
                                    failure_code:)
          expected_files = expected_files.map(&:to_s).sort
          expected_directories = expected_files.flat_map do |path|
            relative = path.delete_prefix("#{root}/")
            parts = relative.split("/")
            (1...parts.length).map do |length|
              "#{root}/#{parts.first(length).join('/')}"
            end
          end.uniq.sort
          files = []
          directories = []
          inventory_input_tree(
            run_id, root, files, directories, depth: 0
          )
          unless files.sort == expected_files &&
                 directories.sort == expected_directories
            raise FailedEvidence, failure_code
          end
        end

        def inventory_input_tree(run_id, relative, files,
                                 directories, depth:)
          if depth > MigrationRepository::MAX_QUALIFICATION_DEPTH
            raise FailedEvidence,
                  "qualification_input_exceeds_bounded_depth"
          end
          children = begin
            @repository.each_qualification_input_child(
              run_id, relative
            )&.to_a
          rescue Hive::ConfigError
            raise FailedEvidence,
                  "qualification_input_unsafe"
          end
          unless children
            raise FailedEvidence,
                  "qualification_input_substitution"
          end
          children.sort.each do |name|
            if files.length + directories.length >=
               MigrationRepository::MAX_QUALIFICATION_FILES
              raise FailedEvidence,
                    "qualification_input_exceeds_bounded_file_count"
            end
            child = "#{relative}/#{name}"
            type = begin
              @repository.qualification_input_entry_type(
                run_id, child
              )
            rescue Hive::ConfigError
              raise FailedEvidence,
                    "qualification_input_unsafe"
            end
            if type == :directory
              directories << child
              inventory_input_tree(
                run_id, child, files, directories,
                depth: depth + 1
              )
            else
              files << child
            end
          end
        end

        def read_input(run_id, relative, max_bytes:, missing_code:)
          bytes = @repository.qualification_input(
            run_id, relative,
            max_bytes: max_bytes,
            missing: true
          )
          raise BlockedEvidence, missing_code unless bytes

          bytes
        rescue BlockedEvidence
          raise
        rescue Hive::ConfigError
          raise FailedEvidence,
                "qualification_input_unsafe"
        end

        def read_input_snapshot(run_id, relative, max_bytes:,
                                missing_code:)
          snapshot = @repository.qualification_input_snapshot(
            run_id, relative,
            max_bytes: max_bytes,
            missing: true
          )
          raise BlockedEvidence, missing_code unless snapshot

          snapshot
        rescue BlockedEvidence
          raise
        rescue Hive::ConfigError
          raise FailedEvidence,
                "qualification_input_unsafe"
        end

        def canonical_json(bytes, failure_code)
          value = JSON.parse(bytes)
          unless bytes ==
                 Hive::WorkflowPackage::CanonicalJSON.generate(value)
            raise FailedEvidence, failure_code
          end
          value
        rescue JSON::ParserError, EncodingError, TypeError
          raise FailedEvidence, failure_code
        end

        def exact!(value, keys, failure_code)
          unless value.is_a?(Hash) &&
                 value.keys.sort == keys.sort
            raise FailedEvidence, failure_code
          end
        end

        def safe_relative?(value)
          return false unless value.is_a?(String) &&
                              !value.empty? &&
                              !value.start_with?("/") &&
                              !value.include?("\\")

          value.split("/", -1).none? do |part|
            part.empty? || part == "." || part == ".."
          end
        end

        def nonempty?(value)
          value.is_a?(String) && !value.empty?
        end

        def integer_or_malformed(value, failure_code)
          Integer(value)
        rescue ArgumentError, TypeError
          raise FailedEvidence, failure_code
        end

        def digest(bytes)
          Digest::SHA256.hexdigest(bytes)
        end

        def blocked(*issues)
          Outcome.new(
            status: "blocked",
            bindings: nil,
            issues: issues.map(&:to_s).uniq.sort.freeze
          ).freeze
        end

        def failed(*issues)
          Outcome.new(
            status: "failed",
            bindings: nil,
            issues: issues.map(&:to_s).uniq.sort.freeze
          ).freeze
        end
      end
    end
  end
end
