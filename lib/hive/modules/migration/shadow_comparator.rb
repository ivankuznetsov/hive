require "digest"
require "json"
require "time"
require "hive/atomic_file"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Writes only namespaced comparison evidence. It receives the immutable
      # production input once, normalizes representation-only fields, and has
      # no access to claims, cursors, repositories, or external gateways.
      class ShadowComparator
        MODULES = %w[patrol architecture-patrol].freeze
        EVIDENCE_SOURCES = %w[legacy_mutator_capture].freeze
        IGNORED_KEYS = %w[duration_ms engine owner recorded_at representation].freeze

        attr_reader :root

        def initialize(root:, clock: -> { Time.now.utc })
          @root = File.expand_path(root)
          @clock = clock
        end

        def record!(module_name:, trigger:, legacy_decision:, module_decision:,
                    configuration_digest:, occurred_at:, legacy_effects: [],
                    module_effects: [], explained_paths: [], comparable: true,
                    evidence_source: nil)
          validate_identity!(module_name, configuration_digest)
          timestamp = time(occurred_at)
          recorded_at = time(@clock.call)
          source = evidence_source&.to_s
          unless source.nil? || EVIDENCE_SOURCES.include?(source)
            raise Hive::ConfigError, "module shadow evidence source is unsupported"
          end
          normalized_legacy = normalize(legacy_decision)
          normalized_module = normalize(module_decision)
          all_differences = differences(normalized_legacy, normalized_module)
          explained = all_differences.select { |row| explained_paths.include?(row.fetch("path")) }
          unexplained = all_differences - explained
          legacy_effects = normalize_effects(legacy_effects)
          module_effects = normalize_effects(module_effects)
          duplicates = duplicate_effects(legacy_effects, module_effects)
          trigger_digest = digest(trigger)
          decision_id = digest("module" => module_name, "trigger_digest" => trigger_digest)
          record = {
            "schema" => "hive-module-shadow-decision", "schema_version" => 1,
            "module" => module_name, "decision_id" => decision_id,
            "trigger_digest" => trigger_digest, "occurred_at" => timestamp.iso8601(6),
            "recorded_at" => recorded_at.iso8601(6), "evidence_source" => source,
            "configuration_digest" => configuration_digest,
            "comparable" => comparable == true && source == "legacy_mutator_capture",
            "legacy" => normalized_legacy,
            "module_decision" => normalized_module,
            "explained_differences" => explained,
            "unexplained_differences" => unexplained,
            "legacy_effects" => legacy_effects, "module_effects" => module_effects,
            "duplicate_effects" => duplicates
          }
          persist(record)
        end

        def records(module_name = nil)
          pattern = module_name ? File.join(root, module_name.to_s, "*.json") : File.join(root, "*", "*.json")
          Dir.glob(pattern).sort.map { |path| read(path) }
        end

        private

        def validate_identity!(module_name, configuration_digest)
          unless MODULES.include?(module_name.to_s) && configuration_digest.to_s.match?(/\A[0-9a-f]{64}\z/)
            raise Hive::ConfigError, "module shadow identity is malformed"
          end
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

        def normalize_effects(effects)
          Array(effects).map do |effect|
            normalized = normalize(effect)
            normalized.is_a?(String) ? normalized : digest(normalized)
          end.sort
        end

        def duplicate_effects(legacy_effects, module_effects)
          repeated_legacy = legacy_effects.tally.select { |_effect, count| count > 1 }.keys
          (repeated_legacy + module_effects).uniq.sort
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
            raise Hive::ConfigError, "module shadow decision identity conflicts with existing evidence"
          end
          Hive::AtomicFile.write(path, bytes, mode: 0o600)
          Hive::AtomicFile.fsync_directory(File.dirname(path))
          record
        end

        def read(path)
          bytes = File.binread(path)
          data = JSON.parse(bytes)
          expected = %w[
            comparable configuration_digest decision_id duplicate_effects
            evidence_source explained_differences legacy legacy_effects module
            module_decision module_effects occurred_at recorded_at schema
            schema_version trigger_digest unexplained_differences
          ]
          unless bytes == canonical(data) && data["schema"] == "hive-module-shadow-decision" &&
                 data["schema_version"] == 1 && data.keys.sort == expected &&
                 MODULES.include?(data["module"]) &&
                 data["decision_id"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                 data["trigger_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                 data["configuration_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                 [ true, false ].include?(data["comparable"]) &&
                 (data["evidence_source"].nil? || EVIDENCE_SOURCES.include?(data["evidence_source"])) &&
                 (!data["comparable"] || data["evidence_source"] == "legacy_mutator_capture") &&
                 %w[
                   duplicate_effects explained_differences legacy_effects module_effects
                   unexplained_differences
                 ].all? { |key| data[key].is_a?(Array) }
            raise Hive::ConfigError, "module shadow evidence is malformed"
          end
          time(data.fetch("occurred_at"))
          time(data.fetch("recorded_at"))
          data
        rescue JSON::ParserError, EncodingError, SystemCallError
          raise Hive::ConfigError, "module shadow evidence is malformed"
        end

        def digest(value) = ::Digest::SHA256.hexdigest(canonical(normalize(value)))
        def canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end
    end
  end
end
