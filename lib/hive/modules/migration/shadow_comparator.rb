require "digest"
require "json"
require "time"
require "hive/managed_directory"
require "hive/modules/migration/bounded_file_inventory"
require "hive/modules/migration/patrol_evidence"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Writes only namespaced comparison evidence. Recovery never consults
      # these records; they are immutable observational inputs to qualification.
      class ShadowComparator
        class IdentityConflict < Hive::ConfigError; end

        ShadowPage = Data.define(:records, :next_cursor)
        MODULES = PatrolEvidence::MODULES
        MAX_RECORD_BYTES = 512 * 1024
        MAX_RECORDS = 4_096
        MAX_PAGE_SIZE = 256
        EVIDENCE_SOURCES = %w[legacy_mutator_capture archived_v1].freeze
        IGNORED_KEYS = %w[duration_ms engine owner recorded_at representation].freeze
        EXPECTED_KEYS = %w[
          comparable configuration_digest decision_id duplicate_effects
          evidence_source explained_differences legacy_capture legacy_effects
          migration module module_decision module_effects occurred_at recorded_at
          schema schema_version semantic_digest trigger trigger_digest
          unexplained_differences
        ].freeze

        attr_reader :root

        def initialize(root:, clock: -> { Time.now.utc },
                       admission_lock: nil)
          @root = File.expand_path(root)
          @clock = clock
          @managed_directory = Hive::ManagedDirectory.new(
            root: @root,
            label: "module shadow evidence"
          )
          @admission_lock = admission_lock || default_admission_lock
        end

        def record!(module_name:, trigger:, module_projection:, configuration_digest:,
                    occurred_at:, legacy_capture: nil, legacy_effects: [],
                    module_effects: [], explained_paths: [], comparable: true)
          @admission_lock.call(shared: true) do
            validate_identity!(module_name, configuration_digest)
            timestamp = time(occurred_at)
            recorded_at = time(@clock.call)
            trigger = PatrolEvidence.trigger(
              normalize(trigger),
              label: "module shadow trigger"
            )
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
            normalized_legacy = normalize(
              capture ? capture.selection.to_h : {}
            )
            normalized_module = normalize(
              projection_value(
                module_projection, module_name
              ).to_h
            )
            all_differences = differences(normalized_legacy, normalized_module)
            explained = all_differences.select { |row| explained_paths.include?(row.fetch("path")) }
            unexplained = all_differences - explained
            trigger_digest = digest(trigger)
            source = capture && "legacy_mutator_capture"
            comparable =
              comparable == true &&
              !capture.nil?
            decision_id = digest(
              "module" => module_name,
              "trigger_digest" => trigger_digest
            )
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
              "comparable" => comparable,
              "legacy_capture" => capture&.to_h,
              "module_decision" => normalized_module,
              "explained_differences" => explained,
              "unexplained_differences" => unexplained,
              "legacy_effects" => legacy_effects.map(&:to_h),
              "module_effects" => module_effects.map(&:to_h),
              "duplicate_effects" => duplicate_effects(legacy_effects, module_effects),
              "migration" => nil
            }
            record["semantic_digest"] = semantic_digest(record)
            persist(record)
          end
        end

        def records_page(module_name:, limit: MAX_PAGE_SIZE, cursor: nil)
          module_name = validated_module_name(module_name)
          limit = validated_page_size(limit)
          @admission_lock.call(shared: true) do
            page = inventory_for(module_name).page(
              limit: limit,
              cursor: cursor
            )
            ShadowPage.new(
              records: page.names.map do |name|
                read(File.join(root, module_name, name))
              end.freeze,
              next_cursor: page.next_cursor
            ).freeze
          end
        end

        def each_record(module_name = nil, page_size: MAX_PAGE_SIZE)
          return enum_for(
            __method__, module_name, page_size: page_size
          ) unless block_given?

          page_size = validated_page_size(page_size)
          modules = module_name ?
            [ validated_module_name(module_name) ] :
            MODULES.sort
          @admission_lock.call(shared: true) do
            inventories = modules.to_h do |name|
              inventory = inventory_for(name)
              [ name, [ inventory, inventory.snapshot ] ]
            end
            total = inventories.values.sum { |_inventory, snapshot| snapshot.count }
            history_overflow! if total > MAX_RECORDS
            inventories.each do |name, (inventory, snapshot)|
              inventory.each_name(
                page_size: page_size,
                snapshot: snapshot
              ) do |filename|
                yield read(File.join(root, name, filename))
              end
            end
          end
          nil
        end

        def validate_record!(value, expected_module: nil,
                             expected_decision_id: nil)
          data = JSON.parse(canonical(value))
          valid = valid_record?(data) &&
                  (!expected_module || data["module"] == expected_module.to_s) &&
                  (!expected_decision_id ||
                   data["decision_id"] == expected_decision_id.to_s)
          raise Hive::ConfigError, "module shadow evidence is malformed" unless valid

          data.freeze
        rescue JSON::GeneratorError, TypeError
          raise Hive::ConfigError, "module shadow evidence is malformed"
        end

        private

        def default_admission_lock
          lock_directory = Hive::ManagedDirectory.new(
            root: File.dirname(root),
            label: "module migration lock"
          )
          lambda do |shared: true, &block|
            lock_directory.with_lock(
              ".mutation.lock",
              shared: shared,
              &block
            )
          end
        end

        def validated_module_name(value)
          name = value.to_s
          return name if MODULES.include?(name)

          raise Hive::ConfigError, "module shadow identity is malformed"
        end

        def validated_page_size(value)
          size = Integer(value)
          return size if size.positive? && size <= MAX_PAGE_SIZE

          raise Hive::ConfigError,
                "module shadow evidence page limit is malformed"
        rescue ArgumentError, TypeError
          raise Hive::ConfigError,
                "module shadow evidence page limit is malformed"
        end

        def inventory_for(module_name)
          Hive::Modules::Migration::BoundedFileInventory.new(
            directory: @managed_directory,
            relative: module_name,
            filename_pattern: /\A[0-9a-f]{64}\.json\z/,
            max_entries: MAX_RECORDS,
            cursor_prefix: "shadow-v1",
            malformed_message: "module shadow evidence is malformed",
            overflow_message:
              "module shadow evidence exceeds the bounded read limit",
            missing: true
          )
        end

        def history_overflow!
          raise Hive::ConfigError,
                "module shadow evidence exceeds the bounded read limit"
        end

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

        def projection_value(value, module_name)
          projection = PatrolDecisionProjection.coerce(value)
          unless projection.module_name == module_name.to_s
            raise Hive::ConfigError,
                  "module shadow decision projection is malformed"
          end
          projection
        rescue Hive::ConfigError
          raise Hive::ConfigError,
                "module shadow decision projection is malformed"
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

          [ { "path" => path, "legacy" => left, "module" => right } ]
        end

        def persist(record)
          path = File.join(root, record.fetch("module"), "#{record.fetch('decision_id')}.json")
          bytes = canonical(record)
          relative = @managed_directory.relative_path(path)
          existing_bytes = @managed_directory.read(
            relative,
            max_bytes: MAX_RECORD_BYTES,
            missing: true
          )
          if existing_bytes
            existing = read(path, bytes: existing_bytes)
            return existing if canonical(existing) == bytes ||
                               existing.merge("recorded_at" => record.fetch("recorded_at")) == record
            raise IdentityConflict,
                  "module shadow decision identity conflicts with existing evidence"
          end
          @managed_directory.atomic_write(relative, bytes, mode: 0o600)
          record
        rescue IdentityConflict
          raise
        rescue Hive::ConfigError
          raise Hive::ConfigError, "module shadow evidence is malformed"
        end

        def read(path, bytes: nil)
          module_name = File.basename(File.dirname(path))
          decision_id = File.basename(path, ".json")
          unless MODULES.include?(module_name) &&
                 decision_id.match?(/\A[0-9a-f]{64}\z/)
            raise Hive::ConfigError, "module shadow evidence is malformed"
          end
          bytes ||= @managed_directory.read(
            @managed_directory.relative_path(path),
            max_bytes: MAX_RECORD_BYTES
          )
          data = JSON.parse(bytes)
          unless bytes == canonical(data)
            raise Hive::ConfigError, "module shadow evidence is malformed"
          end
          validate_record!(
            data,
            expected_module: module_name,
            expected_decision_id: decision_id
          )
        rescue JSON::ParserError, EncodingError, SystemCallError,
               Hive::ConfigError
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
          PatrolEvidence.trigger(
            data["trigger"],
            label: "module shadow trigger"
          )
          return false unless digest(data["trigger"]) == data["trigger_digest"]
          return false if capture && digest(capture.trigger) != data["trigger_digest"]

          legacy_effects = effect_values(
            data["legacy_effects"],
            module_name: data["module"],
            occurrence_id: capture&.occurrence_id
          )
          module_effects = effect_values(
            data["module_effects"],
            module_name: data["module"],
            occurrence_id: capture&.occurrence_id,
            shadow_only: true
          )
          normalized_legacy = normalize(
            capture ? capture.selection.to_h : {}
          )
          normalized_module = normalize(
            projection_value(
              data["module_decision"], data["module"]
            ).to_h
          )
          all_differences = differences(normalized_legacy, normalized_module)
          explained_paths = difference_paths(data["explained_differences"])
          expected_explained = all_differences.select do |row|
            explained_paths.include?(row.fetch("path"))
          end
          return false unless data["explained_differences"] == expected_explained
          return false unless data["unexplained_differences"] ==
                              all_differences - expected_explained
          return false unless data["duplicate_effects"] ==
                              duplicate_effects(legacy_effects, module_effects)
          return false unless data["decision_id"] == digest(
            "module" => data["module"],
            "trigger_digest" => data["trigger_digest"]
          )
          return false unless data["semantic_digest"] == semantic_digest(data)
          true
        end

        def difference_paths(rows)
          paths = rows.map do |row|
            return [] unless row.is_a?(Hash) &&
                             row.keys.sort == %w[legacy module path] &&
                             row["path"].is_a?(String)

            row.fetch("path")
          end
          return [] unless paths.uniq == paths

          paths
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
            data["trigger"].is_a?(Hash) &&
            data["trigger"].keys.sort ==
              %w[archived_v1_trigger_digest kind] &&
            data["trigger"]["kind"] == "archived_v1" &&
            data["trigger"]["archived_v1_trigger_digest"]
              .to_s.match?(/\A[0-9a-f]{64}\z/) &&
            digest(data["trigger"]) == data["trigger_digest"] &&
            data["semantic_digest"] == semantic_digest(data)
        end

        def semantic_digest(record)
          digest(
            record.reject do |key, _value|
              %w[semantic_digest recorded_at].include?(key)
            end
          )
        end

        def digest(value) = ::Digest::SHA256.hexdigest(canonical(normalize(value)))
        def canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end
    end
  end
end
