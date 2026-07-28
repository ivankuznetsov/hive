require "digest"
require "json"
require "time"
require "hive/atomic_file"
require "hive/modules/migration/patrol_evidence"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Writes only namespaced comparison evidence. Recovery never consults
      # these records; they are immutable observational inputs to qualification.
      class ShadowComparator
        MODULES = PatrolEvidence::MODULES
        EVIDENCE_SOURCES = %w[legacy_mutator_capture archived_v1].freeze
        IGNORED_KEYS = %w[duration_ms engine owner recorded_at representation].freeze
        EXPECTED_KEYS = %w[
          comparable configuration_digest decision_id duplicate_effects
          evidence_source explained_differences legacy_capture legacy_effects
          migration module module_decision module_effects occurred_at recorded_at
          schema schema_version trigger trigger_digest unexplained_differences
        ].freeze

        attr_reader :root

        def initialize(root:, clock: -> { Time.now.utc })
          @root = File.expand_path(root)
          @clock = clock
        end

        def record!(module_name:, trigger:, module_decision:, configuration_digest:,
                    occurred_at:, legacy_capture: nil, legacy_effects: [],
                    module_effects: [], explained_paths: [], comparable: true)
          validate_identity!(module_name, configuration_digest)
          timestamp = time(occurred_at)
          recorded_at = time(@clock.call)
          trigger = normalize(trigger)
          capture = capture_value(legacy_capture, module_name, trigger)
          legacy_effects = effect_values(
            legacy_effects, module_name: module_name,
            occurrence_id: capture&.occurrence_id
          )
          module_effects = effect_values(
            module_effects, module_name: module_name,
            occurrence_id: capture&.occurrence_id,
            shadow_only: true
          )
          normalized_legacy = normalize(capture ? capture.decision : {})
          normalized_module = normalize(module_decision)
          all_differences = differences(normalized_legacy, normalized_module)
          explained = all_differences.select { |row| explained_paths.include?(row.fetch("path")) }
          unexplained = all_differences - explained
          trigger_digest = digest(trigger)
          decision_id = digest("module" => module_name, "trigger_digest" => trigger_digest)
          source = capture && "legacy_mutator_capture"
          record = {
            "schema" => "hive-module-shadow-decision",
            "schema_version" => 2,
            "module" => module_name.to_s,
            "decision_id" => decision_id,
            "trigger" => trigger,
            "trigger_digest" => trigger_digest,
            "occurred_at" => timestamp.iso8601(6),
            "recorded_at" => recorded_at.iso8601(6),
            "evidence_source" => source,
            "configuration_digest" => configuration_digest.to_s,
            "comparable" => comparable == true && !capture.nil?,
            "legacy_capture" => capture&.to_h,
            "module_decision" => normalized_module,
            "explained_differences" => explained,
            "unexplained_differences" => unexplained,
            "legacy_effects" => legacy_effects.map(&:to_h),
            "module_effects" => module_effects.map(&:to_h),
            "duplicate_effects" => duplicate_effects(legacy_effects, module_effects),
            "migration" => nil
          }
          persist(record)
        end

        def records(module_name = nil)
          paths = if module_name
            Dir.glob(File.join(root, module_name.to_s, "*.json"))
          else
            MODULES.flat_map { |name| Dir.glob(File.join(root, name, "*.json")) }
          end
          paths.sort.map { |path| read(path) }.freeze
        end

        private

        def validate_identity!(module_name, configuration_digest)
          unless MODULES.include?(module_name.to_s) &&
                 configuration_digest.to_s.match?(/\A[0-9a-f]{64}\z/)
            raise Hive::ConfigError, "module shadow identity is malformed"
          end
        end

        def capture_value(value, module_name, trigger)
          return nil if value.nil?

          capture = value.is_a?(PatrolCapture) ? value : PatrolCapture.from_h(value)
          unless capture.module_name == module_name.to_s &&
                 digest(capture.trigger) == digest(trigger)
            raise Hive::ConfigError,
                  "module shadow legacy capture does not match its occurrence"
          end
          capture
        end

        def effect_values(values, module_name:, occurrence_id:, shadow_only: false)
          effects = Array(values).map do |value|
            value.is_a?(EffectReceipt) ? value : EffectReceipt.from_h(value)
          end
          effects.each do |receipt|
            intent = receipt.intent
            valid = intent.module_name == module_name.to_s &&
                    (!occurrence_id || intent.occurrence_id == occurrence_id)
            valid &&= intent.authority == "shadow" if shadow_only
            unless valid
              raise Hive::ConfigError,
                    "module shadow effect receipt does not match its occurrence"
            end
          end
          effects.sort_by(&:receipt_id).freeze
        end

        def time(value)
          value.is_a?(Time) ? value.utc : Time.iso8601(value.to_s).utc
        rescue ArgumentError
          raise Hive::ConfigError, "module shadow occurrence time is malformed"
        end

        def normalize(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, nested), result|
              key = key.to_s
              result[key] = normalize(nested) unless IGNORED_KEYS.include?(key)
            end.sort.to_h
          when Array then value.map { |nested| normalize(nested) }
          when Symbol then value.to_s
          else value
          end
        end

        def duplicate_effects(legacy_effects, module_effects)
          legacy_ids = legacy_effects.map { |receipt| receipt.intent.intent_id }
          repeated_legacy = legacy_ids.tally.select { |_effect, count| count > 1 }.keys
          module_ids = module_effects.map { |receipt| receipt.intent.intent_id }
          (repeated_legacy + module_ids).uniq.sort
        end

        def differences(left, right, path = "$")
          return [] if left == right
          if left.is_a?(Hash) && right.is_a?(Hash)
            return (left.keys | right.keys).sort.flat_map do |key|
              differences(left[key], right[key], "#{path}.#{key}")
            end
          end
          if left.is_a?(Array) && right.is_a?(Array) && left.length == right.length
            return left.each_index.flat_map do |index|
              differences(left[index], right[index], "#{path}[#{index}]")
            end
          end

          [ { "path" => path, "legacy" => left, "module" => right } ]
        end

        def persist(record)
          path = File.join(root, record.fetch("module"), "#{record.fetch('decision_id')}.json")
          bytes = canonical(record)
          if File.file?(path)
            existing = read(path)
            return existing if canonical(existing) == bytes ||
                               existing.merge("recorded_at" => record.fetch("recorded_at")) == record
            raise Hive::ConfigError,
                  "module shadow decision identity conflicts with existing evidence"
          end
          Hive::AtomicFile.write(path, bytes, mode: 0o600)
          Hive::AtomicFile.fsync_directory(File.dirname(path))
          record
        end

        def read(path)
          bytes = File.binread(path)
          data = JSON.parse(bytes)
          unless bytes == canonical(data) && valid_record?(data)
            raise Hive::ConfigError, "module shadow evidence is malformed"
          end
          data.freeze
        rescue JSON::ParserError, EncodingError, SystemCallError
          raise Hive::ConfigError, "module shadow evidence is malformed"
        end

        def valid_record?(data)
          source_valid = EVIDENCE_SOURCES.include?(data["evidence_source"]) ||
                         data["evidence_source"].nil?
          return false unless data.is_a?(Hash) && data.keys.sort == EXPECTED_KEYS &&
                              data["schema"] == "hive-module-shadow-decision" &&
                              data["schema_version"] == 2 &&
                              MODULES.include?(data["module"]) &&
                              data["decision_id"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                              data["trigger_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                              data["configuration_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                              data["trigger"].is_a?(Hash) &&
                              [ true, false ].include?(data["comparable"]) &&
                              source_valid

          valid_evidence?(data)
        rescue Hive::ConfigError, NoMethodError, TypeError
          false
        end

        def valid_evidence?(data)
          return false unless %w[
            duplicate_effects explained_differences legacy_effects module_effects
            unexplained_differences
          ].all? { |key| data[key].is_a?(Array) }
          time(data.fetch("occurred_at"))
          time(data.fetch("recorded_at"))
          return valid_migrated_record?(data) unless data["migration"].nil?

          capture = data["legacy_capture"] && PatrolCapture.from_h(data["legacy_capture"])
          return false if data["comparable"] && capture.nil?
          return false unless data["evidence_source"] == (capture && "legacy_mutator_capture")
          return false if capture && capture.module_name != data["module"]
          return false unless digest(data["trigger"]) == data["trigger_digest"]

          effect_values(
            data["legacy_effects"],
            module_name: data["module"],
            occurrence_id: capture&.occurrence_id
          )
          effect_values(
            data["module_effects"],
            module_name: data["module"],
            occurrence_id: capture&.occurrence_id,
            shadow_only: true
          )
          true
        end

        def valid_migrated_record?(data)
          migration = data["migration"]
          migration.is_a?(Hash) &&
            migration.keys.sort == %w[source_digest source_schema_version status] &&
            migration["source_schema_version"] == 1 &&
            migration["status"] == "archived_non_comparable" &&
            migration["source_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
            data["comparable"] == false &&
            data["evidence_source"] == "archived_v1" &&
            data["legacy_capture"].nil? &&
            data["legacy_effects"].empty? &&
            data["module_effects"].empty? &&
            data["duplicate_effects"].empty? &&
            digest(data["trigger"]) == data["trigger_digest"]
        end

        def digest(value) = ::Digest::SHA256.hexdigest(canonical(normalize(value)))
        def canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end
    end
  end
end
