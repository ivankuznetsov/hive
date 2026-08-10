require "time"
require "json"
require "digest"
require "hive/managed_directory"
require "hive/modules/migration/shadow_comparator"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      class Report
        MIN_ELAPSED_SECONDS = 7 * 24 * 60 * 60
        MIN_DECISIONS = 10
        MAX_REPORT_BYTES = 128 * 1024

        attr_reader :payload

        Storage = Data.define(:directory, :filename)
        private_constant :Storage

        def self.build(record_source:, reviewer:, reviewed_at:,
                       generated_at: reviewed_at)
          new(
            record_source: record_source,
            reviewer: reviewer,
            reviewed_at: reviewed_at,
            generated_at: generated_at
          )
        end

        def self.load(path)
          bytes = read_bytes(path)
          payload = parse_current(bytes)
          require "hive/modules/migration/report_projection"
          ReportProjection.from_h(payload)
        rescue JSON::ParserError, EncodingError, SystemCallError
          raise Hive::ConfigError, "module migration report is missing or unreadable"
        end

        def self.read_bytes(path)
          with_locked_storage(path, shared: true) do |storage|
            read_locked(storage)
          end
        rescue Hive::ConfigError
          raise Hive::ConfigError, "module migration report is missing or unreadable"
        end

        def self.canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)

        def self.valid_payload?(payload) = valid_legacy_payload?(payload)

        def self.valid_legacy_payload?(payload)
          return false unless payload.is_a?(Hash) &&
                              payload["schema"] == "hive-module-migration-report" &&
                              payload["schema_version"] == 1
          return valid_legacy_error?(payload) if payload["ok"] == false

          success_keys = %w[
            blockers eligible generated_at modules reviewed_at reviewer schema
            schema_version window
          ]
          return false unless payload.keys.sort == success_keys &&
                              [ true, false ].include?(payload["eligible"]) &&
                              payload["generated_at"].is_a?(String) &&
                              payload["reviewer"].is_a?(String) &&
                              payload["reviewed_at"].is_a?(String) &&
                              valid_legacy_window?(payload["window"]) &&
                              payload["blockers"].is_a?(Array) &&
                              payload["blockers"].all? { |value| value.is_a?(String) } &&
                              payload["modules"].is_a?(Hash) &&
                              payload["modules"].keys.sort == ShadowComparator::MODULES.sort
          payload["modules"].values.all? { |value| valid_legacy_summary?(value) }
        rescue NoMethodError
          false
        end

        def self.valid_legacy_error?(payload)
          required = %w[error_kind exit_code message ok schema schema_version]
          (required - payload.keys).empty? &&
            payload["error_kind"].is_a?(String) &&
            payload["exit_code"].is_a?(Integer) &&
            payload["message"].is_a?(String)
        end
        private_class_method :valid_legacy_error?

        def self.valid_legacy_window?(value)
          value.is_a?(Hash) &&
            %w[started_at ended_at].all? { |key| value.key?(key) }
        end
        private_class_method :valid_legacy_window?

        def self.valid_legacy_summary?(value)
          keys = %w[
            blockers configuration_digest decision_count duplicate_effect_count
            elapsed_seconds ended_at started_at unexplained_difference_count
          ]
          value.is_a?(Hash) && value.keys.sort == keys &&
            value["decision_count"].is_a?(Integer) &&
            value["decision_count"] >= 0 &&
            value["elapsed_seconds"].is_a?(Integer) &&
            value["elapsed_seconds"] >= 0 &&
            [ value["started_at"], value["ended_at"] ].all? do |timestamp|
              timestamp.nil? || timestamp.is_a?(String)
            end &&
            value["unexplained_difference_count"].is_a?(Integer) &&
            value["unexplained_difference_count"] >= 0 &&
            value["duplicate_effect_count"].is_a?(Integer) &&
            value["duplicate_effect_count"] >= 0 &&
            (value["configuration_digest"].nil? ||
              value["configuration_digest"].is_a?(String)) &&
            value["blockers"].is_a?(Array) &&
            value["blockers"].all? { |blocker| blocker.is_a?(String) }
        end
        private_class_method :valid_legacy_summary?

        def self.with_locked_storage(path, shared: false)
          storage = storage_for(path)
          storage.directory.with_lock(".mutation.lock", shared: shared) do
            yield storage
          end
        end

        def self.read_locked(storage, name: storage.filename,
                             max_bytes: MAX_REPORT_BYTES, missing: false)
          storage.directory.read(
            name, max_bytes: max_bytes, missing: missing
          )
        end

        def self.write_locked(storage, bytes, name: storage.filename,
                              expected_digest: nil,
                              max_existing_bytes: MAX_REPORT_BYTES)
          storage.directory.atomic_write(
            name, bytes, mode: 0o600,
            expected_digest: expected_digest,
            max_existing_bytes: max_existing_bytes
          )
        end

        def self.digest_bytes(bytes)
          ::Digest::SHA256.hexdigest(bytes)
        end

        def self.write_projection(path, projection, expected_digest: nil)
          require "hive/modules/migration/report_projection"
          projection = projection.is_a?(ReportProjection) ?
            ReportProjection.from_h(projection.to_h) :
            ReportProjection.from_h(projection)
          bytes = canonical(projection.to_h)
          if bytes.bytesize > MAX_REPORT_BYTES
            raise Hive::ConfigError, "module migration report is malformed"
          end
          with_locked_storage(path) do |storage|
            current = read_locked(storage, missing: true)
            if current == bytes
              if expected_digest && digest_bytes(current) != expected_digest
                raise Hive::ConfigError,
                      "module migration report expected digest does not match"
              end
              next
            end
            if current
              current_payload = parse_current(current)
              if current_payload["schema_version"] == 1
                raise Hive::ConfigError,
                      "module migration report v1 requires one-off migration"
              end
              ReportProjection.validate_successor!(
                current: current_payload, successor: projection
              )
            end
            if current && expected_digest.nil?
              raise Hive::ConfigError,
                    "module migration report replacement requires expected digest"
            end
            write_locked(storage, bytes, expected_digest: expected_digest)
          end
          path
        rescue JSON::ParserError
          raise Hive::ConfigError, "module migration report is malformed"
        end

        def self.storage_for(path)
          expanded = File.expand_path(path)
          Storage.new(
            directory: Hive::ManagedDirectory.new(
              root: File.dirname(expanded),
              label: "module migration report"
            ),
            filename: File.basename(expanded).freeze
          )
        end
        private_class_method :storage_for

        def self.parse_current(bytes)
          payload = JSON.parse(bytes)
          unless payload.is_a?(Hash) && bytes == canonical(payload)
            raise Hive::ConfigError, "module migration report is malformed"
          end
          payload
        rescue JSON::ParserError, EncodingError, ArgumentError, TypeError
          raise Hive::ConfigError, "module migration report is malformed"
        end
        private_class_method :parse_current

        def initialize(record_source:, reviewer:, reviewed_at:, generated_at:)
          validator = ShadowComparator.new(root: Dir.pwd)
          @reviewer = reviewer.to_s.strip
          @reviewed_at = parse_time(reviewed_at)
          @generated_at = parse_time(generated_at)
          @module_states = ShadowComparator::MODULES.to_h do |module_name|
            [ module_name, empty_module_state ]
          end
          consume(record_source, validator)
          @payload = build_payload.freeze
        end

        def eligible? = payload.fetch("eligible")
        def blockers = payload.fetch("blockers")
        def configuration_digests = payload.fetch("modules").transform_values { |row| row["configuration_digest"] }

        def write(path)
          bytes = self.class.canonical(payload)
          self.class.with_locked_storage(path) do |storage|
            current = self.class.read_locked(storage, missing: true)
            if current && self.class.send(
              :parse_current, current
            )["schema_version"] == 2
              raise Hive::ConfigError,
                    "module migration report v2 cannot be replaced by v1"
            end
            expected = current && self.class.digest_bytes(current)
            self.class.write_locked(
              storage, bytes, expected_digest: expected
            )
          end
          path
        rescue JSON::ParserError
          raise Hive::ConfigError, "module migration report is malformed"
        end

        private

        def build_payload
          modules = ShadowComparator::MODULES.to_h do |module_name|
            [ module_name, module_summary(module_name) ]
          end
          blockers = modules.flat_map do |module_name, summary|
            Array(summary.fetch("blockers")).map { |reason| "#{module_name}:#{reason}" }
          end
          latest = modules.values.filter_map { |summary| summary["ended_at"] }.map { |value| parse_time(value) }.max
          blockers << "reviewer_signoff_missing" if @reviewer.empty?
          blockers << "review_predates_evidence" if latest && @reviewed_at < latest
          starts = modules.values.filter_map { |row| row["started_at"] }
          ends = modules.values.filter_map { |row| row["ended_at"] }
          {
            "schema" => "hive-module-migration-report", "schema_version" => 1,
            "generated_at" => @generated_at.iso8601(6), "reviewer" => @reviewer,
            "reviewed_at" => @reviewed_at.iso8601(6),
            "window" => { "started_at" => starts.min, "ended_at" => ends.max },
            "modules" => modules, "eligible" => blockers.empty?, "blockers" => blockers.sort
          }
        end

        def module_summary(module_name)
          state = @module_states.fetch(module_name)
          blockers = []
          if state.fetch(:count) < MIN_DECISIONS
            blockers << "decision_count_below_#{MIN_DECISIONS}"
          end
          started_at = state.fetch(:started_at)
          ended_at = state.fetch(:ended_at)
          elapsed = started_at && ended_at ? ended_at - started_at : 0
          blockers << "observation_window_below_7_days" if elapsed < MIN_ELAPSED_SECONDS
          blockers << "unexplained_differences" if state.fetch(:unexplained).positive?
          blockers << "duplicate_effects" if state.fetch(:duplicates).positive?
          blockers << "configuration_changed" if state.fetch(:configuration_changed) ||
                                                  state.fetch(:configuration_digest).nil?
          {
            "decision_count" => state.fetch(:count),
            "started_at" => started_at&.iso8601(6),
            "ended_at" => ended_at&.iso8601(6),
            "elapsed_seconds" => elapsed.to_i,
            "configuration_digest" =>
              state.fetch(:configuration_changed) ?
                nil :
                state.fetch(:configuration_digest),
            "unexplained_difference_count" => state.fetch(:unexplained),
            "duplicate_effect_count" => state.fetch(:duplicates),
            "blockers" => blockers
          }
        end

        def empty_module_state
          {
            count: 0,
            started_at: nil,
            ended_at: nil,
            configuration_digest: nil,
            configuration_changed: false,
            unexplained: 0,
            duplicates: 0
          }
        end

        def consume(record_source, validator)
          seen = 0
          record_source.each do |value|
            seen += 1
            if seen > ShadowComparator::MAX_RECORDS
              raise Hive::ConfigError,
                    "module shadow evidence exceeds the bounded read limit"
            end
            record = validator.validate_record!(value)
            next unless record["comparable"] == true

            accumulate(record)
          end
        rescue NoMethodError, TypeError
          raise Hive::ConfigError, "module shadow evidence is malformed"
        end

        def accumulate(record)
          state = @module_states.fetch(record.fetch("module"))
          timestamp = parse_time(record.fetch("recorded_at"))
          digest = record.fetch("configuration_digest")
          state[:count] += 1
          state[:started_at] = timestamp if state[:started_at].nil? ||
                                            timestamp < state[:started_at]
          state[:ended_at] = timestamp if state[:ended_at].nil? ||
                                          timestamp > state[:ended_at]
          if state[:configuration_digest] &&
             state[:configuration_digest] != digest
            state[:configuration_changed] = true
          else
            state[:configuration_digest] ||= digest
          end
          state[:unexplained] += record.fetch("unexplained_differences").length
          state[:duplicates] += record.fetch("duplicate_effects").length
        end

        def parse_time(value)
          value.is_a?(Time) ? value.utc : Time.iso8601(value.to_s).utc
        rescue ArgumentError
          raise Hive::ConfigError, "module migration report time is malformed"
        end
      end
    end
  end
end
