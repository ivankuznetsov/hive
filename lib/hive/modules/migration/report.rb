require "time"
require "json"
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

        Loaded = Data.define(:payload) do
          def eligible? = payload.fetch("eligible")
          def blockers = payload.fetch("blockers")
          def configuration_digests
            payload.fetch("modules").transform_values { |row| row["configuration_digest"] }
          end
        end

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
          payload = JSON.parse(bytes)
          unless bytes == canonical(payload) && valid_payload?(payload)
            raise Hive::ConfigError, "module migration report is malformed"
          end
          Loaded.new(payload: payload.freeze)
        rescue JSON::ParserError, EncodingError, SystemCallError
          raise Hive::ConfigError, "module migration report is missing or unreadable"
        end

        def self.read_bytes(path)
          expanded = File.expand_path(path)
          directory = Hive::ManagedDirectory.new(
            root: File.dirname(expanded),
            label: "module migration report"
          )
          directory.read(
            File.basename(expanded),
            max_bytes: MAX_REPORT_BYTES
          )
        rescue Hive::ConfigError
          raise Hive::ConfigError, "module migration report is missing or unreadable"
        end

        def self.canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)

        def self.valid_payload?(payload)
          payload.is_a?(Hash) && payload["schema"] == "hive-module-migration-report" &&
            payload["schema_version"] == 1 && [ true, false ].include?(payload["eligible"]) &&
            payload["modules"].is_a?(Hash) && payload["modules"].keys.sort == ShadowComparator::MODULES.sort &&
            payload["blockers"].is_a?(Array)
        rescue NoMethodError
          false
        end

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
          expanded = File.expand_path(path)
          directory = Hive::ManagedDirectory.new(
            root: File.dirname(expanded),
            label: "module migration report"
          )
          directory.atomic_write(
            File.basename(expanded),
            self.class.canonical(payload),
            mode: 0o600
          )
          path
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
