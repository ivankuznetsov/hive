require "time"
require "hive/modules/migration/patrol_evidence_verifier"
require "hive/modules/migration/patrol_qualification"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/modules/migration/report_projection"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # A transport projection over freshly verified Patrol qualification
      # bundles. The report never persists an independent eligibility bit:
      # `evidence_ready_for_operator` is rebuilt from both lane bundles.
      class Report
        SCHEMA = "hive-module-migration-report".freeze
        SCHEMA_VERSION = 2
        STATUSES = %w[
          failed blocked evidence_required evidence_ready_for_operator
        ].freeze
        REQUIRED_LANES = %w[deterministic installed].freeze
        MAX_REPORT_BYTES = 512 * 1024
        MAX_BUNDLE_BYTES = 16 * 1024 * 1024
        TOP_LEVEL_KEYS = %w[
          blockers candidate configuration_digests generated_at lanes
          migration report_id reviewed_at reviewer run_id
          scenario_manifest_digest schema schema_version status
        ].freeze
        LANE_KEYS = %w[
          blockers bundle_digest bundle_path effect_index_digest receipt_id
          status
        ].freeze
        MIGRATION_KEYS = %w[
          archive_path source_digest source_schema_version status
        ].freeze
        BUNDLE_KEYS = %w[receipt records].freeze
        BUNDLE_PATH = %r{\Areport-evidence/[0-9a-f]{64}\.json\z}

        Qualification = PatrolQualification

        attr_reader :payload, :qualification

        class << self
          def build(run_id:, lane_evidence:, reviewer:, reviewed_at:,
                    generated_at: reviewed_at, migration: nil,
                    live_bindings_resolver: nil)
            ReportProjection.build(
              run_id: run_id,
              lane_evidence: lane_evidence,
              reviewer: reviewer,
              reviewed_at: reviewed_at,
              generated_at: generated_at,
              migration: migration,
              live_bindings_resolver: live_bindings_resolver
            )
          end

          def evidence_required(blockers:, reviewer:, reviewed_at:,
                                generated_at: reviewed_at,
                                run_id: nil,
                                configuration_digests: nil,
                                candidate: nil,
                                scenario_manifest_digest: nil,
                                migration: nil)
            reviewer = reviewer.to_s.strip
            blockers = normalize_blockers(blockers)
            configuration_digests = normalize_optional_configurations(
              configuration_digests
            )
            candidate = normalize_optional_candidate(candidate)
            scenario_manifest_digest = optional_digest(
              scenario_manifest_digest
            )
            body = {
              "schema" => SCHEMA,
              "schema_version" => SCHEMA_VERSION,
              "run_id" => normalize_optional_run_id(run_id),
              "status" => "evidence_required",
              "blockers" => blockers,
              "candidate" => candidate,
              "configuration_digests" => configuration_digests,
              "scenario_manifest_digest" => scenario_manifest_digest,
              "lanes" => REQUIRED_LANES.to_h do |lane|
                [ lane, missing_lane_row ]
              end.freeze,
              "reviewer" => reviewer,
              "reviewed_at" => timestamp(reviewed_at),
              "generated_at" => timestamp(generated_at),
              "migration" => normalize_migration(migration)
            }
            from_projection(body, bundles: {}, verifications: {})
          end

          def canonical(value)
            Hive::WorkflowPackage::CanonicalJSON.generate(value)
          end

          def valid_payload?(value)
            return false unless
              value.is_a?(Hash) &&
              value.keys.sort == TOP_LEVEL_KEYS &&
              value["schema"] == SCHEMA &&
              value["schema_version"] == SCHEMA_VERSION &&
              STATUSES.include?(value["status"]) &&
              valid_run_binding?(value) &&
              value["report_id"].to_s.match?(
                /\Amigration-report-[0-9a-f]{64}\z/
              ) &&
              valid_string_array?(value["blockers"]) &&
              valid_candidate?(value["candidate"], optional: true) &&
              valid_configurations?(
                value["configuration_digests"], optional: true
              ) &&
              optional_hex_digest?(value["scenario_manifest_digest"]) &&
              value["lanes"].is_a?(Hash) &&
              value["lanes"].keys.sort == REQUIRED_LANES &&
              value["lanes"].all? do |lane, row|
                valid_lane_row?(lane, row)
              end &&
              value["reviewer"].is_a?(String) &&
              valid_time?(value["reviewed_at"]) &&
              valid_time?(value["generated_at"]) &&
              valid_migration?(value["migration"])

            expected_id = report_id_for(
              value.reject { |key, _item| key == "report_id" }
            )
            value["report_id"] == expected_id
          rescue KeyError, NoMethodError, TypeError
            false
          end

          def valid_bundle_shape?(value)
            value.is_a?(Hash) && value.keys.sort == BUNDLE_KEYS &&
              value["records"].respond_to?(:each)
          rescue NoMethodError
            false
          end

          private

          def from_projection(body, bundles:, verifications:)
            payload = PatrolEvidence.immutable_json(
              body.merge("report_id" => report_id_for(body)),
              label: "module migration report"
            )
            PatrolEvidence.bounded!(
              payload,
              max_bytes: MAX_REPORT_BYTES,
              label: "module migration report"
            )
            qualification = qualification_for(
              payload, verifications
            )
            allocate.tap do |report|
              report.send(
                :initialize_projection,
                payload,
                bundles,
                qualification
              )
            end
          end

          def loaded_evidence_required(payload)
            unless payload["status"] == "evidence_required" &&
                   payload["lanes"].values.all? do |row|
                     row["bundle_path"].nil?
                   end
              raise Hive::ConfigError,
                    "module migration report evidence is missing"
            end
            qualification = qualification_for(payload, {})
            allocate.tap do |report|
              report.send(
                :initialize_projection,
                PatrolEvidence.immutable_json(
                  payload,
                  label: "module migration report"
                ),
                {},
                qualification
              )
            end
          end

          def qualification_for(payload, verifications)
            PatrolQualification.build(
              status: payload.fetch("status"),
              blockers: payload.fetch("blockers"),
              run_id: payload.fetch("run_id"),
              configuration_digests:
                payload.fetch("configuration_digests"),
              candidate: payload.fetch("candidate"),
              scenario_manifest_digest:
                payload.fetch("scenario_manifest_digest"),
              verifications: verifications.freeze,
              report_id: payload.fetch("report_id")
            ).freeze
          end

          def normalize_blockers(values)
            blockers = Array(values).map do |value|
              PatrolEvidence.nonempty(
                value,
                label: "module migration report"
              )
            end
            blockers.uniq.sort.freeze
          end

          def normalize_optional_configurations(value)
            return PatrolEvidence::MODULES.sort.to_h do |module_name|
              [ module_name, nil ]
            end.freeze if value.nil?

            unless valid_configurations?(value, optional: true)
              PatrolEvidence.malformed!("module migration report")
            end
            PatrolEvidence::MODULES.sort.to_h do |module_name|
              item = value.fetch(module_name)
              [ module_name, item&.dup&.freeze ]
            end.freeze
          end

          def normalize_optional_candidate(value)
            return nil if value.nil?
            PatrolEvidence.malformed!("module migration report") unless
              valid_candidate?(value, optional: true)
            PatrolEvidence.immutable_json(
              value,
              label: "module migration report"
            )
          end

          def normalize_optional_run_id(value)
            return nil if value.nil?
            string = value.to_s
            PatrolEvidence.malformed!(
              "module migration report"
            ) unless
              QualificationRunDescriptor::RUN_ID.match?(string)
            string.freeze
          end

          def normalize_migration(value)
            return nil if value.nil?
            value = PatrolEvidence.immutable_json(
              value,
              label: "module migration report"
            )
            PatrolEvidence.malformed!("module migration report") unless
              valid_migration?(value)
            value
          end

          def optional_digest(value)
            return nil if value.nil?
            string = value.to_s
            PatrolEvidence.malformed!("module migration report") unless
              string.match?(/\A[0-9a-f]{64}\z/)
            string.freeze
          end

          def timestamp(value)
            PatrolEvidence.timestamp(
              value,
              label: "module migration report"
            )
          end

          def missing_lane_row
            {
              "status" => "blocked",
              "blockers" => [ "lane_evidence_missing" ].freeze,
              "receipt_id" => nil,
              "effect_index_digest" => nil,
              "bundle_path" => nil,
              "bundle_digest" => nil
            }.freeze
          end

          def report_id_for(body)
            PatrolEvidence.digest("migration-report", body)
          end

          def valid_lane_row?(lane, row)
            row.is_a?(Hash) && row.keys.sort == LANE_KEYS &&
              %w[
                verified blocked failed evidence_required
              ].include?(row["status"]) &&
              valid_string_array?(row["blockers"]) &&
              optional_prefixed_digest?(
                row["receipt_id"], "patrol-evidence"
              ) &&
              optional_prefixed_digest?(
                row["effect_index_digest"], "effect-index"
              ) &&
              ((row["bundle_path"].nil? &&
                row["bundle_digest"].nil? &&
                row["receipt_id"].nil? &&
                row["effect_index_digest"].nil?) ||
               (row["bundle_path"].to_s.match?(BUNDLE_PATH) &&
                hex_digest?(row["bundle_digest"]))) &&
              (row["status"] != "verified" ||
               row["bundle_path"] &&
               REQUIRED_LANES.include?(lane))
          end

          def valid_candidate?(value, optional:)
            return optional if value.nil?
            value.is_a?(Hash) &&
              value.keys.sort == PatrolEvidenceReceipt::CANDIDATE_KEYS &&
              value["commit_sha"].to_s.match?(
                /\A[0-9a-f]{40}\z/
              ) &&
              (
                PatrolEvidenceReceipt::CANDIDATE_KEYS -
                  [ "commit_sha" ]
              ).all? do |key|
                hex_digest?(value[key])
              end
          end

          def valid_run_binding?(value)
            run_id = value["run_id"]
            return QualificationRunDescriptor::RUN_ID.match?(
              run_id.to_s
            ) unless run_id.nil?

            value["status"] == "evidence_required" &&
              value["lanes"].is_a?(Hash) &&
              value["lanes"].values.all? do |row|
                row.is_a?(Hash) &&
                  row["bundle_path"].nil? &&
                  row["bundle_digest"].nil?
              end
          end

          def valid_configurations?(value, optional:)
            value.is_a?(Hash) &&
              value.keys.sort == PatrolEvidence::MODULES.sort &&
              value.values.all? do |digest|
                (optional && digest.nil?) || hex_digest?(digest)
              end
          end

          def valid_migration?(value)
            return true if value.nil?
            value.is_a?(Hash) &&
              value.keys.sort == MIGRATION_KEYS &&
              value["source_schema_version"] == 1 &&
              value["source_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
              value["archive_path"].to_s.match?(
                %r{\Aarchive/report-v1/[0-9a-f]{64}\.json\z}
              ) &&
              value["status"] == "archived_evidence_required"
          end

          def valid_string_array?(value)
            value.is_a?(Array) &&
              value.all? { |item| item.is_a?(String) && !item.empty? } &&
              value.uniq == value &&
              value.sort == value
          end

          def valid_time?(value)
            Time.iso8601(value.to_s)
            true
          rescue ArgumentError
            false
          end

          def hex_digest?(value)
            value.to_s.match?(/\A[0-9a-f]{64}\z/)
          end

          def optional_hex_digest?(value)
            value.nil? || hex_digest?(value)
          end

          def optional_prefixed_digest?(value, prefix)
            value.nil? ||
              value.to_s.match?(
                /\A#{Regexp.escape(prefix)}-[0-9a-f]{64}\z/
              )
          end
        end

        def status = payload.fetch("status")
        def blockers = payload.fetch("blockers")
        def configuration_digests
          payload.fetch("configuration_digests")
        end
        private

        def initialize_projection(payload, bundles, qualification)
          @payload = payload.freeze
          @bundles = bundles.freeze
          @qualification = qualification
        end

        def bundle_bytes
          @bundles
        end
      end
    end
  end
end
