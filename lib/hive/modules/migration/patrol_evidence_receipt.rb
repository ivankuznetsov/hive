require "json"
require "time"
require "hive/managed_directory"
require "hive/modules/migration/patrol_evidence"

module Hive
  module Modules
    module Migration
      class PatrolEvidenceReceipt < Data.define(:payload)
        SCHEMA = "hive-patrol-evidence-receipt".freeze
        SCHEMA_VERSION = 1
        MAX_RECEIPT_BYTES = 512 * 1024
        MAX_DECISIONS = 4_096
        MAX_ARTIFACTS = 64
        MAX_STRING_BYTES = PatrolEvidence::MAX_STRING_BYTES
        LANES = %w[deterministic installed].freeze
        LANE_RESULTS = %w[passed blocked failed].freeze
        CONTROLS = %w[
          none ordinary_positive_finding architecture_positive_thesis
          clean_negative
        ].freeze
        TOP_LEVEL_KEYS = %w[
          artifacts candidate configuration_digests decisions effects faults
          generated_at lane lane_result matrix module_selections observed
          project receipt_id reviewer reviewed_at run_id
          scenario_manifest_digest schema schema_version
        ].freeze
        CANDIDATE_KEYS = %w[
          catalog_digest installed_digest manifest_digest sha source_digest
        ].freeze
        DECISION_KEYS = %w[
          control decision_class decision_id module record_digest repository
          repository_sha trigger_digest
        ].freeze
        EFFECT_KEYS = %w[
          expected_legacy_keys index_digest
        ].freeze
        OBSERVED_KEYS = %w[
          elapsed_seconds ended_at restart_count started_at
        ].freeze
        PROJECT_KEYS = %w[name project_id repository].freeze
        MODULE_SELECTION_KEYS = %w[active selection_epoch].freeze
        ACTIVE_SELECTION_KEYS = %w[
          catalog_commit configuration_digest manifest_digest source_commit
          version
        ].freeze

        class << self
          def build(run_id:, lane:, lane_result:, candidate:,
                    configuration_digests:, scenario_manifest_digest:,
                    project:, module_selections:,
                    decision_refs:, matrix:, faults:, restart_count:,
                    effect_index_digest:, expected_legacy_effect_keys:,
                    artifact_digests:, reviewer:, generated_at:, reviewed_at:,
                    observed_started_at:, observed_ended_at:,
                    failure_reason: nil)
            label = "patrol evidence receipt"
            run_id = PatrolEvidence.nonempty(run_id, label: label)
            lane = PatrolEvidence.enum(lane, LANES, label: label)
            lane_result = PatrolEvidence.enum(
              lane_result, LANE_RESULTS, label: label
            )
            failure_reason = normalize_failure_reason(
              lane_result, failure_reason, label
            )
            candidate = normalize_candidate(candidate, lane, label)
            configuration_digests = normalize_configuration_digests(
              configuration_digests, label
            )
            project = normalize_project(project, label)
            module_selections = normalize_module_selections(
              module_selections,
              label
            )
            scenario_manifest_digest = hex_digest(
              scenario_manifest_digest, label
            )
            decisions = normalize_decisions(decision_refs, label)
            matrix = normalize_string_set(matrix, label: label, max: 64)
            faults = normalize_string_set(faults, label: label, max: 32)
            restart_count = nonnegative_integer(restart_count, label)
            effects = {
              "index_digest" => prefixed_digest(
                effect_index_digest, "effect-index", label
              ),
              "expected_legacy_keys" => normalize_effect_keys(
                expected_legacy_effect_keys, label
              )
            }.freeze
            artifacts = normalize_artifacts(artifact_digests, label)
            reviewer = PatrolEvidence.nonempty(reviewer, label: label)
            generated_at = PatrolEvidence.timestamp(
              generated_at, label: label
            )
            reviewed_at = PatrolEvidence.timestamp(
              reviewed_at, label: label
            )
            observed = normalize_observed(
              observed_started_at, observed_ended_at, restart_count, label
            )
            body = {
              "schema" => SCHEMA,
              "schema_version" => SCHEMA_VERSION,
              "run_id" => run_id,
              "lane" => lane,
              "lane_result" => {
                "status" => lane_result,
                "reason" => failure_reason
              }.freeze,
              "candidate" => candidate,
              "configuration_digests" => configuration_digests,
              "project" => project,
              "module_selections" => module_selections,
              "scenario_manifest_digest" => scenario_manifest_digest,
              "decisions" => decisions,
              "matrix" => matrix,
              "faults" => faults,
              "effects" => effects,
              "artifacts" => artifacts,
              "reviewer" => reviewer,
              "generated_at" => generated_at,
              "reviewed_at" => reviewed_at,
              "observed" => observed
            }
            receipt_id = PatrolEvidence.digest(
              "patrol-evidence", body
            )
            payload = PatrolEvidence.immutable_json(
              body.merge("receipt_id" => receipt_id),
              label: label
            )
            PatrolEvidence.bounded!(
              payload,
              max_bytes: MAX_RECEIPT_BYTES,
              label: label
            )
            new(payload: payload).freeze
          end

          def from_h(value)
            label = "patrol evidence receipt"
            value = PatrolEvidence.immutable_json(value, label: label)
            PatrolEvidence.exact_keys!(value, TOP_LEVEL_KEYS, label: label)
            PatrolEvidence.malformed!(label) unless
              value["schema"] == SCHEMA &&
              value["schema_version"] == SCHEMA_VERSION
            lane_result = value.fetch("lane_result")
            PatrolEvidence.exact_keys!(
              lane_result, %w[reason status], label: label
            )
            effects = value.fetch("effects")
            PatrolEvidence.exact_keys!(effects, EFFECT_KEYS, label: label)
            observed = value.fetch("observed")
            PatrolEvidence.exact_keys!(observed, OBSERVED_KEYS, label: label)
            rebuilt = build(
              run_id: value["run_id"],
              lane: value["lane"],
              lane_result: lane_result["status"],
              failure_reason: lane_result["reason"],
              candidate: value["candidate"],
              configuration_digests: value["configuration_digests"],
              project: value["project"],
              module_selections: value["module_selections"],
              scenario_manifest_digest: value["scenario_manifest_digest"],
              decision_refs: value["decisions"],
              matrix: value["matrix"],
              faults: value["faults"],
              restart_count: observed["restart_count"],
              effect_index_digest: effects["index_digest"],
              expected_legacy_effect_keys:
                effects["expected_legacy_keys"],
              artifact_digests: value["artifacts"],
              reviewer: value["reviewer"],
              generated_at: value["generated_at"],
              reviewed_at: value["reviewed_at"],
              observed_started_at: observed["started_at"],
              observed_ended_at: observed["ended_at"]
            )
            unless rebuilt.receipt_id == value["receipt_id"]
              raise Hive::ConfigError,
                    "patrol evidence receipt identity does not match its contents"
            end
            PatrolEvidence.malformed!(label) unless
              canonical(rebuilt.to_h) == canonical(value)

            rebuilt
          rescue KeyError, NoMethodError, TypeError
            PatrolEvidence.malformed!(label)
          end

          def load(path)
            expanded = File.expand_path(path)
            directory = Hive::ManagedDirectory.new(
              root: File.dirname(expanded),
              label: "patrol evidence receipt"
            )
            bytes = directory.read(
              File.basename(expanded),
              max_bytes: MAX_RECEIPT_BYTES
            )
            payload = JSON.parse(bytes)
            PatrolEvidence.malformed!("patrol evidence receipt") unless
              bytes == canonical(payload)
            from_h(payload)
          rescue JSON::ParserError, EncodingError, SystemCallError,
                 Hive::ConfigError
            raise Hive::ConfigError,
                  "patrol evidence receipt is missing or unreadable"
          end

          def canonical(value)
            Hive::WorkflowPackage::CanonicalJSON.generate(value)
          end

          private

          def normalize_candidate(value, lane, label)
            value = PatrolEvidence.immutable_json(value, label: label)
            PatrolEvidence.exact_keys!(value, CANDIDATE_KEYS, label: label)
            candidate = {
              "sha" => git_sha(value["sha"], label),
              "catalog_digest" => hex_digest(
                value["catalog_digest"], label
              ),
              "source_digest" => hex_digest(value["source_digest"], label),
              "manifest_digest" => hex_digest(
                value["manifest_digest"], label
              ),
              "installed_digest" =>
                value["installed_digest"] &&
                  hex_digest(value["installed_digest"], label)
            }.freeze
            installed = !candidate["installed_digest"].nil?
            PatrolEvidence.malformed!(label) unless
              (lane == "installed") == installed
            candidate
          end

          def normalize_configuration_digests(value, label)
            value = PatrolEvidence.immutable_json(value, label: label)
            PatrolEvidence.exact_keys!(
              value, PatrolEvidence::MODULES, label: label
            )
            PatrolEvidence::MODULES.sort.to_h do |module_name|
              [ module_name, hex_digest(value[module_name], label) ]
            end.freeze
          end

          def normalize_project(value, label)
            value = PatrolEvidence.immutable_json(
              value,
              label: label
            )
            PatrolEvidence.exact_keys!(
              value,
              PROJECT_KEYS,
              label: label
            )
            {
              "project_id" => PatrolEvidence.nonempty(
                value["project_id"],
                label: label
              ),
              "name" => PatrolEvidence.nonempty(
                value["name"],
                label: label
              ),
              "repository" =>
                value["repository"] &&
                  PatrolEvidence.nonempty(
                    value["repository"],
                    label: label
                  )
            }.freeze
          end

          def normalize_module_selections(value, label)
            value = PatrolEvidence.immutable_json(
              value,
              label: label
            )
            PatrolEvidence.exact_keys!(
              value,
              PatrolEvidence::MODULES,
              label: label
            )
            PatrolEvidence::MODULES.sort.to_h do |module_name|
              selection = value.fetch(module_name)
              PatrolEvidence.exact_keys!(
                selection,
                MODULE_SELECTION_KEYS,
                label: label
              )
              epoch = Integer(selection["selection_epoch"])
              PatrolEvidence.malformed!(label) unless
                epoch.positive?
              active = selection.fetch("active")
              PatrolEvidence.exact_keys!(
                active,
                ACTIVE_SELECTION_KEYS,
                label: label
              )
              normalized_active = {
                "version" => PatrolEvidence.nonempty(
                  active["version"],
                  label: label
                ),
                "catalog_commit" => git_sha(
                  active["catalog_commit"],
                  label
                ),
                "source_commit" => git_sha(
                  active["source_commit"],
                  label
                ),
                "manifest_digest" => hex_digest(
                  active["manifest_digest"],
                  label
                ),
                "configuration_digest" => hex_digest(
                  active["configuration_digest"],
                  label
                )
              }.freeze
              [
                module_name,
                {
                  "selection_epoch" => epoch,
                  "active" => normalized_active
                }.freeze
              ]
            end.freeze
          rescue ArgumentError, TypeError
            PatrolEvidence.malformed!(label)
          end

          def normalize_decisions(value, label)
            decisions = Array(value).map do |row|
              row = PatrolEvidence.immutable_json(row, label: label)
              PatrolEvidence.exact_keys!(
                row, DECISION_KEYS, label: label
              )
              {
                "decision_id" => hex_digest(row["decision_id"], label),
                "module" => PatrolEvidence.enum(
                  row["module"], PatrolEvidence::MODULES, label: label
                ),
                "decision_class" => PatrolEvidence.nonempty(
                  row["decision_class"], label: label
                ),
                "repository" => PatrolEvidence.nonempty(
                  row["repository"], label: label
                ),
                "repository_sha" => git_sha(
                  row["repository_sha"], label
                ),
                "trigger_digest" => hex_digest(
                  row["trigger_digest"], label
                ),
                "record_digest" => hex_digest(
                  row["record_digest"], label
                ),
                "control" => PatrolEvidence.enum(
                  row["control"], CONTROLS, label: label
                )
              }.freeze
            end
            PatrolEvidence.malformed!(label) if
              decisions.empty? || decisions.length > MAX_DECISIONS
            decisions.sort_by! { |row| row.fetch("decision_id") }
            PatrolEvidence.malformed!(label) unless
              decisions.map { |row| row.fetch("decision_id") }.uniq.length ==
                decisions.length
            decisions.freeze
          end

          def normalize_artifacts(value, label)
            value = PatrolEvidence.immutable_json(value, label: label)
            PatrolEvidence.malformed!(label) unless
              value.is_a?(Hash) &&
              value.length.between?(1, MAX_ARTIFACTS)
            value.keys.sort.to_h do |name|
              PatrolEvidence.malformed!(label) unless
                name.match?(/\A[a-z0-9][a-z0-9_.-]*\z/)
              [ name.dup.freeze, hex_digest(value[name], label) ]
            end.freeze
          end

          def normalize_string_set(value, label:, max:)
            values = Array(value).map do |item|
              PatrolEvidence.nonempty(item, label: label)
            end
            PatrolEvidence.malformed!(label) if
              values.empty? || values.length > max ||
              values.uniq.length != values.length
            values.sort.freeze
          end

          def normalize_effect_keys(value, label)
            values = Array(value).map do |item|
              prefixed_digest(item, "effect", label)
            end
            PatrolEvidence.malformed!(label) unless
              values.uniq.length == values.length
            values.sort.freeze
          end

          def normalize_observed(started_at, ended_at, restart_count, label)
            started_at = PatrolEvidence.timestamp(
              started_at, label: label
            )
            ended_at = PatrolEvidence.timestamp(ended_at, label: label)
            elapsed_seconds = Time.iso8601(ended_at) - Time.iso8601(started_at)
            PatrolEvidence.malformed!(label) if elapsed_seconds.negative?
            {
              "started_at" => started_at,
              "ended_at" => ended_at,
              "elapsed_seconds" => elapsed_seconds.to_i,
              "restart_count" => restart_count
            }.freeze
          end

          def normalize_failure_reason(lane_result, value, label)
            if lane_result == "passed"
              PatrolEvidence.malformed!(label) unless value.nil?
              return nil
            end
            PatrolEvidence.nonempty(value, label: label)
          end

          def nonnegative_integer(value, label)
            integer = Integer(value)
            PatrolEvidence.malformed!(label) if integer.negative?
            integer
          rescue ArgumentError, TypeError
            PatrolEvidence.malformed!(label)
          end

          def git_sha(value, label)
            string = value.to_s
            PatrolEvidence.malformed!(label) unless
              string.match?(/\A[0-9a-f]{40}\z/)
            string.dup.freeze
          end

          def hex_digest(value, label)
            string = value.to_s
            PatrolEvidence.malformed!(label) unless
              string.match?(/\A[0-9a-f]{64}\z/)
            string.dup.freeze
          end

          def prefixed_digest(value, prefix, label)
            string = value.to_s
            PatrolEvidence.malformed!(label) unless
              string.match?(/\A#{Regexp.escape(prefix)}-[0-9a-f]{64}\z/)
            string.dup.freeze
          end
        end

        def receipt_id = payload.fetch("receipt_id")
        def lane = payload.fetch("lane")
        def lane_result = payload.dig("lane_result", "status")
        def failure_reason = payload.dig("lane_result", "reason")
        def configuration_digests = payload.fetch("configuration_digests")
        def decision_refs = payload.fetch("decisions")
        def matrix = payload.fetch("matrix")
        def faults = payload.fetch("faults")
        def effect_index_digest = payload.dig("effects", "index_digest")
        def expected_legacy_effect_keys
          payload.dig("effects", "expected_legacy_keys")
        end
        def to_h = payload

        def write(path)
          expanded = File.expand_path(path)
          directory = Hive::ManagedDirectory.new(
            root: File.dirname(expanded),
            label: "patrol evidence receipt"
          )
          directory.atomic_write(
            File.basename(expanded),
            self.class.canonical(payload),
            mode: 0o600
          )
          path
        end
      end
    end
  end
end
