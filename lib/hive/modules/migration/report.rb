require "time"
require "json"
require "hive/atomic_file"
require "hive/modules/migration/shadow_comparator"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      class Report
        MIN_ELAPSED_SECONDS = 7 * 24 * 60 * 60
        MIN_DECISIONS = 10

        attr_reader :payload

        Loaded = Data.define(:payload) do
          def eligible? = payload.fetch("eligible")
          def blockers = payload.fetch("blockers")
          def configuration_digests
            payload.fetch("modules").transform_values { |row| row["configuration_digest"] }
          end
        end

        def self.build(records:, reviewer:, reviewed_at:, generated_at: reviewed_at)
          new(records: records, reviewer: reviewer, reviewed_at: reviewed_at, generated_at: generated_at)
        end

        def self.load(path)
          bytes = File.binread(path)
          payload = JSON.parse(bytes)
          unless bytes == canonical(payload) && valid_payload?(payload)
            raise Hive::ConfigError, "module migration report is malformed"
          end
          Loaded.new(payload: payload.freeze)
        rescue JSON::ParserError, EncodingError, SystemCallError
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

        def initialize(records:, reviewer:, reviewed_at:, generated_at:)
          @records = Array(records)
          @reviewer = reviewer.to_s.strip
          @reviewed_at = parse_time(reviewed_at)
          @generated_at = parse_time(generated_at)
          @payload = build_payload.freeze
        end

        def eligible? = payload.fetch("eligible")
        def blockers = payload.fetch("blockers")
        def configuration_digests = payload.fetch("modules").transform_values { |row| row["configuration_digest"] }

        def write(path)
          Hive::AtomicFile.write(path, self.class.canonical(payload), mode: 0o600)
          Hive::AtomicFile.fsync_directory(File.dirname(path))
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
          records = @records.select { |row| row["module"] == module_name }
          comparable = records.select { |row| row["comparable"] == true }
          times = comparable.filter_map { |row| parse_time(row["occurred_at"]) }
          digests = comparable.filter_map { |row| row["configuration_digest"] }.uniq
          unexplained = comparable.sum { |row| Array(row["unexplained_differences"]).length }
          duplicates = comparable.sum { |row| Array(row["duplicate_effects"]).length }
          blockers = []
          blockers << "decision_count_below_#{MIN_DECISIONS}" if comparable.length < MIN_DECISIONS
          elapsed = times.length > 1 ? times.max - times.min : 0
          blockers << "observation_window_below_7_days" if elapsed < MIN_ELAPSED_SECONDS
          blockers << "unexplained_differences" if unexplained.positive?
          blockers << "duplicate_effects" if duplicates.positive?
          blockers << "configuration_changed" unless digests.length == 1
          {
            "decision_count" => comparable.length,
            "started_at" => times.min&.iso8601(6), "ended_at" => times.max&.iso8601(6),
            "elapsed_seconds" => elapsed.to_i,
            "configuration_digest" => digests.one? ? digests.first : nil,
            "unexplained_difference_count" => unexplained,
            "duplicate_effect_count" => duplicates, "blockers" => blockers
          }
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
