require "time"
require "hive/modules/migration/patrol_evidence_receipt"
require "hive/modules/migration/patrol_effect_index"

module Hive
  module Modules
    module Migration
      class PatrolEvidenceVerifier
        MIN_DECISIONS_PER_MODULE = 10
        MIN_CLASSES_PER_MODULE = 5
        REQUIRED_MATRIX = %w[
          ordinary_positive_finding architecture_positive_thesis
          clean_negative due not_due new_commit same_commit
          capacity_deferral quota_deferral cooldown_retry timer_reset_reload
          restart concurrent_duplicate_delivery partial_failure launch_failure
          reconciliation_failure
        ].sort.freeze
        REQUIRED_FAULTS = %w[
          after_legacy_capture after_legacy_decision after_module_decision
          after_effect_intent during_reconciliation
        ].sort.freeze
        BINDING_KEYS = %w[
          artifact_digests candidate configuration_digests
          decision_expectations expected_legacy_effect_keys lane
          required_matrix run_id scenario_manifest_digest
        ].freeze

        Verification = Data.define(
          :status, :blockers, :receipt, :effect_index,
          :configuration_digests
        ) do
          def verified? = status == "verified"
        end

        class << self
          def verify(receipt:, records:, current_bindings:)
            receipt = receipt.is_a?(PatrolEvidenceReceipt) ?
              receipt :
              PatrolEvidenceReceipt.from_h(receipt)
            bindings = normalize_bindings(current_bindings)
            records = validated_records(records)
            effect_index = PatrolEffectIndex.build(records: records)
            blockers = []

            verify_lane(receipt, blockers)
            verify_current_bindings(receipt, bindings, blockers)
            verify_decisions(receipt, records, bindings, blockers)
            verify_controls(receipt, records, blockers)
            verify_effects(receipt, effect_index, bindings, blockers)
            verify_protocol(receipt, blockers)
            verify_review_time(receipt, records, blockers)

            blockers = blockers.uniq.sort.freeze
            status = if receipt.lane_result == "blocked"
              "blocked"
            elsif receipt.lane_result == "failed"
              "failed"
            elsif blockers.empty?
              "verified"
            else
              "evidence_required"
            end
            Verification.new(
              status: status,
              blockers: blockers,
              receipt: receipt,
              effect_index: effect_index,
              configuration_digests: receipt.configuration_digests
            ).freeze
          end

          private

          def normalize_bindings(value)
            label = "patrol evidence current bindings"
            value = PatrolEvidence.immutable_json(value, label: label)
            PatrolEvidence.exact_keys!(value, BINDING_KEYS, label: label)
            candidate = value.fetch("candidate")
            PatrolEvidence.exact_keys!(
              candidate,
              PatrolEvidenceReceipt::CANDIDATE_KEYS,
              label: label
            )
            configuration_digests = value.fetch(
              "configuration_digests"
            )
            PatrolEvidence.exact_keys!(
              configuration_digests,
              PatrolEvidence::MODULES,
              label: label
            )
            artifacts = value.fetch("artifact_digests")
            PatrolEvidence.malformed!(label) unless artifacts.is_a?(Hash)
            expectations = Array(value.fetch("decision_expectations")).map do |row|
              PatrolEvidence.exact_keys!(
                row,
                PatrolEvidenceReceipt::DECISION_KEYS - [ "record_digest" ],
                label: label
              )
              row
            end
            PatrolEvidence.malformed!(label) unless
              expectations.map { |row| row["decision_id"] }.uniq.length ==
                expectations.length
            normalized = value.merge(
              "decision_expectations" =>
                expectations.sort_by { |row| row.fetch("decision_id") },
              "required_matrix" =>
                Array(value.fetch("required_matrix")).map(&:to_s).sort,
              "expected_legacy_effect_keys" =>
                Array(value.fetch("expected_legacy_effect_keys"))
                  .map(&:to_s)
                  .sort
            )
            validate_binding_shapes!(normalized, label)
            PatrolEvidence.immutable_json(normalized, label: label)
          rescue KeyError, NoMethodError, TypeError
            PatrolEvidence.malformed!(label)
          end

          def validate_binding_shapes!(value, label)
            PatrolEvidence.nonempty(value["run_id"], label: label)
            PatrolEvidence.enum(
              value["lane"], PatrolEvidenceReceipt::LANES, label: label
            )
            candidate = value["candidate"]
            git_sha!(candidate["sha"], label)
            %w[
              catalog_digest source_digest manifest_digest
            ].each { |key| hex_digest!(candidate[key], label) }
            installed = candidate["installed_digest"]
            if value["lane"] == "installed"
              hex_digest!(installed, label)
            else
              PatrolEvidence.malformed!(label) unless installed.nil?
            end
            value["configuration_digests"].each_value do |digest|
              hex_digest!(digest, label)
            end
            hex_digest!(value["scenario_manifest_digest"], label)
            value["artifact_digests"].each do |name, digest|
              PatrolEvidence.nonempty(name, label: label)
              hex_digest!(digest, label)
            end
            value["decision_expectations"].each do |row|
              hex_digest!(row["decision_id"], label)
              PatrolEvidence.enum(
                row["module"], PatrolEvidence::MODULES, label: label
              )
              PatrolEvidence.nonempty(
                row["decision_class"], label: label
              )
              PatrolEvidence.nonempty(row["repository"], label: label)
              git_sha!(row["repository_sha"], label)
              hex_digest!(row["trigger_digest"], label)
              PatrolEvidence.enum(
                row["control"],
                PatrolEvidenceReceipt::CONTROLS,
                label: label
              )
            end
            value["required_matrix"].each do |item|
              PatrolEvidence.nonempty(item, label: label)
            end
            value["expected_legacy_effect_keys"].each do |key|
              PatrolEvidence.hex_id(key, "effect", label: label)
            end
          end

          def validated_records(source)
            validator = ShadowComparator.new(root: Dir.pwd)
            records = []
            source.each do |value|
              if records.length >= ShadowComparator::MAX_RECORDS
                raise Hive::ConfigError,
                      "module shadow evidence exceeds the bounded read limit"
              end
              records << validator.validate_record!(value)
            end
            records.freeze
          rescue NoMethodError, TypeError
            raise Hive::ConfigError, "module shadow evidence is malformed"
          end

          def verify_lane(receipt, blockers)
            return if receipt.lane_result == "passed"

            blockers << [
              "lane_#{receipt.lane_result}",
              receipt.failure_reason
            ].compact.join(":")
          end

          def verify_current_bindings(receipt, bindings, blockers)
            payload = receipt.to_h
            blockers << "run_binding_mismatch" unless
              payload["run_id"] == bindings["run_id"]
            blockers << "lane_binding_mismatch" unless
              payload["lane"] == bindings["lane"]
            blockers << "candidate_binding_mismatch" unless
              payload["candidate"] == bindings["candidate"]
            blockers << "configuration_binding_mismatch" unless
              payload["configuration_digests"] ==
                bindings["configuration_digests"]
            blockers << "scenario_manifest_binding_mismatch" unless
              payload["scenario_manifest_digest"] ==
                bindings["scenario_manifest_digest"]
            blockers << "artifact_binding_mismatch" unless
              payload["artifacts"] == bindings["artifact_digests"]
            blockers << "scenario_matrix_mismatch" unless
              receipt.matrix == bindings["required_matrix"]
            blockers << "legacy_effect_expectation_mismatch" unless
              receipt.expected_legacy_effect_keys ==
                bindings["expected_legacy_effect_keys"]
          end

          def verify_decisions(receipt, records, bindings, blockers)
            record_ids = records.map { |record| record.fetch("decision_id") }
            reference_ids = receipt.decision_refs.map do |row|
              row.fetch("decision_id")
            end
            blockers << "duplicate_decision_records" unless
              record_ids.uniq.length == record_ids.length
            blockers << "decision_set_mismatch" unless
              record_ids.uniq.sort == reference_ids.sort

            expected_refs = bindings.fetch("decision_expectations")
            actual_refs = receipt.decision_refs.map do |row|
              row.reject { |key, _value| key == "record_digest" }
            end
            blockers << "decision_binding_mismatch" unless
              actual_refs == expected_refs

            records_by_id = records.to_h do |record|
              [ record.fetch("decision_id"), record ]
            end
            receipt.decision_refs.each do |reference|
              record = records_by_id[reference.fetch("decision_id")]
              next unless record

              verify_record(
                reference,
                record,
                bindings.fetch("configuration_digests"),
                blockers
              )
            end
            PatrolEvidence::MODULES.each do |module_name|
              module_refs = receipt.decision_refs.select do |row|
                row["module"] == module_name &&
                  records_by_id.key?(row["decision_id"])
              end
              blockers << "#{module_name}:unique_decisions_below_#{MIN_DECISIONS_PER_MODULE}" if
                module_refs.map { |row| row["decision_id"] }.uniq.length <
                  MIN_DECISIONS_PER_MODULE
              blockers << "#{module_name}:decision_classes_below_#{MIN_CLASSES_PER_MODULE}" if
                module_refs.map { |row| row["decision_class"] }.uniq.length <
                  MIN_CLASSES_PER_MODULE
              blockers << "#{module_name}:repository_states_below_2" if
                module_refs.map { |row| row["repository_sha"] }.uniq.length < 2
            end
          end

          def verify_record(reference, record, configuration_digests, blockers)
            decision_id = reference.fetch("decision_id")
            prefix = "decision:#{decision_id}"
            blockers << "#{prefix}:module_mismatch" unless
              record["module"] == reference["module"]
            blockers << "#{prefix}:trigger_mismatch" unless
              record["trigger_digest"] == reference["trigger_digest"]
            blockers << "#{prefix}:record_digest_mismatch" unless
              record["semantic_digest"] == reference["record_digest"]
            blockers << "#{prefix}:not_authoritative" unless
              record["comparable"] == true &&
              record["evidence_source"] == "legacy_mutator_capture" &&
              record["migration"].nil? &&
              record.dig("legacy_capture", "owner") == "legacy"
            blockers << "#{prefix}:repository_mismatch" unless
              record.dig("legacy_capture", "project", "repository") ==
                reference["repository"]
            blockers << "#{prefix}:configuration_mismatch" unless
              record["configuration_digest"] ==
                configuration_digests.fetch(reference["module"])
            blockers << "#{prefix}:unexplained_differences" unless
              record["unexplained_differences"].empty?
            blockers << "#{prefix}:row_duplicate_effects" unless
              record["duplicate_effects"].empty?
          end

          def verify_controls(receipt, records, blockers)
            records_by_id = records.to_h do |record|
              [ record.fetch("decision_id"), record ]
            end
            controls = receipt.decision_refs.group_by do |row|
              row.fetch("control")
            end
            unless control_matches?(
              controls["ordinary_positive_finding"],
              records_by_id,
              module_name: "patrol",
              rationale: "due"
            ) do |capture|
              capture.dig("outcome", "findings").to_i.positive? &&
                Array(capture.dig("outcome", "finding_ids")).any?
            end
              blockers << "ordinary_positive_control_failed"
            end
            unless control_matches?(
              controls["architecture_positive_thesis"],
              records_by_id,
              module_name: "architecture-patrol",
              rationale: "due"
            ) do |capture|
              capture.dig("outcome", "action_count").to_i.positive? &&
                !capture.dig("outcome", "job_id").to_s.empty?
            end
              blockers << "architecture_positive_control_failed"
            end
            negatives = Array(controls["clean_negative"])
            negative_ok = negatives.any? do |reference|
              record = records_by_id[reference["decision_id"]]
              next false unless record &&
                                record.dig("module_decision", "rationale") ==
                                  "not_due"

              capture = record.fetch("legacy_capture")
              capture.dig("outcome", "findings").to_i.zero? &&
                capture.dig("outcome", "action_count").to_i.zero?
            end
            blockers << "clean_negative_control_failed" unless negative_ok
          end

          def control_matches?(references, records_by_id, module_name:,
                               rationale:)
            Array(references).any? do |reference|
              record = records_by_id[reference["decision_id"]]
              next false unless
                record &&
                reference["module"] == module_name &&
                record.dig("module_decision", "rationale") == rationale

              yield record.fetch("legacy_capture")
            end
          end

          def verify_effects(receipt, index, bindings, blockers)
            blockers << "effect_index_mismatch" unless
              receipt.effect_index_digest == index.digest
            blockers << "run_wide_duplicate_effects" unless
              index.duplicate_keys.empty?
            blockers << "module_shadow_effects_present" unless
              index.module_count.zero?
            blockers << "legacy_effect_authority_mismatch" unless
              index.entries
                .select { |entry| entry["channel"] == "legacy" }
                .all? { |entry| entry["authority"] == "legacy" }
            blockers << "legacy_effect_cardinality_mismatch" unless
              index.legacy_keys ==
                bindings.fetch("expected_legacy_effect_keys")
          end

          def verify_protocol(receipt, blockers)
            blockers << "required_matrix_incomplete" unless
              (REQUIRED_MATRIX - receipt.matrix).empty?
            decision_classes = receipt.decision_refs.map do |row|
              row.fetch("decision_class")
            end.uniq
            blockers << "decision_class_evidence_incomplete" unless
              (REQUIRED_MATRIX - decision_classes).empty?
            blockers << "fault_matrix_incomplete" unless
              (REQUIRED_FAULTS - receipt.faults).empty?
            blockers << "restart_evidence_missing" unless
              receipt.to_h.dig("observed", "restart_count").positive?
          end

          def verify_review_time(receipt, records, blockers)
            latest = records
              .map { |record| Time.iso8601(record.fetch("recorded_at")) }
              .max
            reviewed_at = Time.iso8601(receipt.to_h.fetch("reviewed_at"))
            blockers << "review_predates_evidence" if
              latest && reviewed_at < latest
          end

          def git_sha!(value, label)
            PatrolEvidence.malformed!(label) unless
              value.to_s.match?(/\A[0-9a-f]{40}\z/)
          end

          def hex_digest!(value, label)
            PatrolEvidence.malformed!(label) unless
              value.to_s.match?(/\A[0-9a-f]{64}\z/)
          end
        end
      end
    end
  end
end
