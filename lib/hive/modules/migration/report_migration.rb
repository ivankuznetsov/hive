require "digest"
require "json"
require "time"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/report"

module Hive
  module Modules
    module Migration
      # One-off, project-local replacement of the released report v1. Exact v1
      # bytes are archived before a v2 evidence-required projection replaces
      # the runtime file. Report itself remains v2-only.
      class ReportMigration
        MAX_LEGACY_BYTES = 128 * 1024
        LEGACY_REPORT_KEYS = %w[
          blockers eligible generated_at modules reviewed_at reviewer schema
          schema_version window
        ].freeze
        LEGACY_SUMMARY_KEYS = %w[
          blockers configuration_digest decision_count
          duplicate_effect_count elapsed_seconds ended_at started_at
          unexplained_difference_count
        ].freeze
        LEGACY_ERROR_KEYS = %w[
          error_kind exit_code message ok schema schema_version
        ].freeze
        LEGACY_ERROR_TIME = Time.at(0).utc.freeze
        RECEIPT_PATH = "migrations/report-v2.json".freeze
        RECEIPT_KEYS = %w[
          archive_digest archive_path replacement_digest schema
          schema_version source_digest status
        ].freeze
        RECEIPT_SCHEMA =
          "hive-module-migration-report-migration".freeze
        MAX_RECEIPT_BYTES = 16 * 1024
        Result = Data.define(
          :status,
          :report,
          :archive_path,
          :source_digest,
          :migration
        )

        def initialize(path:, repository: nil, after_archive: -> { },
                       after_replace: -> { })
          @path = File.expand_path(path)
          @after_archive = after_archive
          @after_replace = after_replace
          @repository = repository || MigrationRepository.new(
            root: File.dirname(@path)
          )
          unless @repository.report_path == @path
            raise Hive::ConfigError,
                  "module migration report repository does not match path"
          end
        end

        def ensure_current!
          @repository.with_lock do
            ensure_current_unlocked!
          end
        end

        private

        def ensure_current_unlocked!
          bytes = @repository.read_report_bytes(missing: true)
          return result("absent") unless bytes

          payload = parse_canonical(bytes)
          if payload["schema"] == Report::SCHEMA &&
             payload["schema_version"] == Report::SCHEMA_VERSION
            unless Report.valid_payload?(payload)
              raise Hive::ConfigError,
                    "module migration report is malformed"
            end
            report = if payload.fetch("lanes").values.all? do |row|
              row.fetch("bundle_path").nil?
            end
              Report.send(:loaded_evidence_required, payload)
            end
            initial_replacement = initial_replacement_for(
              payload["migration"]
            )
            repair_or_verify_receipt!(
              payload["migration"],
              initial_replacement_bytes: initial_replacement,
              current_bytes: bytes
            )
            return result(
              "current",
              report: report,
              migration: payload["migration"]
            )
          end
          migrate_v1!(bytes, payload)
        end

        def migrate_v1!(bytes, payload)
          unless bytes.bytesize <= MAX_LEGACY_BYTES &&
                 valid_legacy_payload?(payload)
            raise Hive::ConfigError,
                  "legacy module migration report is malformed"
          end
          digest = Digest::SHA256.hexdigest(bytes)
          archive_path = "archive/report-v1/#{digest}.json"
          archive!(archive_path, bytes)
          @after_archive.call
          migration = {
            "source_schema_version" => 1,
            "source_digest" => digest,
            "archive_path" => archive_path,
            "status" => "archived_evidence_required"
          }
          report = initial_replacement_report(
            payload,
            migration
          )
          replacement = Report.canonical(report.payload)
          @repository.write_report_bytes(
            replacement,
            expected_digest: digest
          )
          @after_replace.call
          verify_archive!(archive_path, digest)
          repair_or_verify_receipt!(
            migration,
            initial_replacement_bytes: replacement,
            current_bytes: replacement
          )
          report = @repository.load_report
          result(
            "migrated",
            report: report,
            archive_path: archive_path,
            source_digest: digest,
            migration: migration
          )
        end

        def archive!(relative, bytes)
          existing = @repository.read_archive(
            relative,
            missing: true
          )
          if existing
            unless existing == bytes
              raise Hive::ConfigError,
                    "legacy module migration report archive conflicts with existing bytes"
            end
            return
          end
          @repository.write_archive(relative, bytes)
        end

        def initial_replacement_for(migration)
          return unless migration

          legacy_payload = verify_archive!(
            migration.fetch("archive_path"),
            migration.fetch("source_digest")
          )
          Report.canonical(
            initial_replacement_report(
              legacy_payload,
              migration
            ).payload
          )
        rescue KeyError
          raise Hive::ConfigError,
                "module migration report archive binding is malformed"
        end

        def initial_replacement_report(payload, migration,
                                       configurations: nil)
          if valid_legacy_error_payload?(payload)
            return Report.evidence_required(
              blockers: [
                "legacy_v1_error_report_archived"
              ],
              reviewer: "",
              reviewed_at: LEGACY_ERROR_TIME,
              generated_at: LEGACY_ERROR_TIME,
              migration: migration
            )
          end

          configurations ||= payload.fetch("modules").to_h do |name, row|
            [ name, row.fetch("configuration_digest") ]
          end
          Report.evidence_required(
            blockers: [
              "legacy_v1_evidence_missing_candidate_and_protocol_bindings"
            ],
            reviewer: payload.fetch("reviewer"),
            reviewed_at: payload.fetch("reviewed_at"),
            generated_at: payload.fetch("generated_at"),
            configuration_digests: configurations,
            migration: migration
          )
        end

        def repair_or_verify_receipt!(migration,
                                      initial_replacement_bytes:,
                                      current_bytes:)
          return if migration.nil?
          payload = {
            "schema" => RECEIPT_SCHEMA,
            "schema_version" => 1,
            "status" => "complete",
            "source_digest" => migration.fetch("source_digest"),
            "archive_path" => migration.fetch("archive_path"),
            "archive_digest" => migration.fetch("source_digest"),
            "replacement_digest" =>
              Digest::SHA256.hexdigest(initial_replacement_bytes)
          }
          expected = Report.canonical(payload)
          existing = @repository.read_receipt(
            RECEIPT_PATH,
            missing: true
          )
          if existing
            unless existing == expected && valid_receipt?(existing)
              raise Hive::ConfigError,
                    "module migration report migration receipt conflicts"
            end
            return
          end
          unless current_bytes == initial_replacement_bytes
            raise Hive::ConfigError,
                  "module migration report migration receipt is missing after report evolution"
          end
          @repository.write_receipt(RECEIPT_PATH, expected)
        end

        def valid_receipt?(bytes)
          value = JSON.parse(bytes)
          bytes == Report.canonical(value) &&
            value.is_a?(Hash) &&
            value.keys.sort == RECEIPT_KEYS &&
            value["schema"] == RECEIPT_SCHEMA &&
            value["schema_version"] == 1 &&
            value["status"] == "complete" &&
            %w[
              source_digest archive_digest replacement_digest
            ].all? do |key|
              value[key].to_s.match?(/\A[0-9a-f]{64}\z/)
            end &&
            value["archive_path"].to_s.match?(
              %r{\Aarchive/report-v1/[0-9a-f]{64}\.json\z}
            )
        rescue JSON::ParserError, NoMethodError
          false
        end

        def verify_archive!(relative, expected_digest)
          bytes = @repository.read_archive(relative)
          unless Digest::SHA256.hexdigest(bytes) == expected_digest
            raise Hive::ConfigError,
                  "module migration report archive digest changed"
          end
          payload = parse_canonical(bytes)
          unless valid_legacy_payload?(payload)
            raise Hive::ConfigError,
                  "legacy module migration report archive is malformed"
          end
          payload
        rescue Hive::ConfigError
          raise
        rescue SystemCallError, IOError
          raise Hive::ConfigError,
                "legacy module migration report archive is missing or unreadable"
        end

        def parse_canonical(bytes)
          payload = JSON.parse(bytes)
          unless bytes == Report.canonical(payload)
            raise Hive::ConfigError,
                  "module migration report is not canonical"
          end
          payload
        rescue JSON::ParserError, EncodingError
          raise Hive::ConfigError, "module migration report is malformed"
        end

        def valid_legacy_payload?(value)
          valid_legacy_success_payload?(value) ||
            valid_legacy_error_payload?(value)
        end

        def valid_legacy_success_payload?(value)
          return false unless
            value.is_a?(Hash) &&
            value.keys.sort == LEGACY_REPORT_KEYS &&
            value["schema"] == Report::SCHEMA &&
            value["schema_version"] == 1 &&
            [ true, false ].include?(value["eligible"]) &&
            string_array?(value["blockers"]) &&
            value["reviewer"].is_a?(String) &&
            valid_time?(value["reviewed_at"]) &&
            valid_time?(value["generated_at"]) &&
            valid_window?(value["window"]) &&
            value["modules"].is_a?(Hash) &&
            value["modules"].keys.sort == PatrolEvidence::MODULES.sort

          value["modules"].all? do |_name, row|
            valid_legacy_summary?(row)
          end
        rescue NoMethodError, TypeError
          false
        end

        def valid_legacy_error_payload?(value)
          value.is_a?(Hash) &&
            value.keys.sort == LEGACY_ERROR_KEYS &&
            value["schema"] == Report::SCHEMA &&
            value["schema_version"] == 1 &&
            value["ok"] == false &&
            value["error_kind"].is_a?(String) &&
            value["exit_code"].is_a?(Integer) &&
            value["message"].is_a?(String)
        rescue NoMethodError, TypeError
          false
        end

        def valid_legacy_summary?(row)
          row.is_a?(Hash) &&
            row.keys.sort == LEGACY_SUMMARY_KEYS &&
            string_array?(row["blockers"]) &&
            (
              row["configuration_digest"].nil? ||
              row["configuration_digest"].to_s.match?(
                /\A[0-9a-f]{64}\z/
              )
            ) &&
            %w[
              decision_count duplicate_effect_count elapsed_seconds
              unexplained_difference_count
            ].all? do |key|
              row[key].is_a?(Integer) && !row[key].negative?
            end &&
            [ row["started_at"], row["ended_at"] ].all? do |value|
              value.nil? || valid_time?(value)
            end
        end

        def valid_window?(value)
          value.is_a?(Hash) &&
            value.keys.sort == %w[ended_at started_at] &&
            value.values.all? { |item| item.nil? || valid_time?(item) }
        end

        def valid_time?(value)
          Time.iso8601(value.to_s)
          true
        rescue ArgumentError
          false
        end

        def string_array?(value)
          value.is_a?(Array) &&
            value.all? { |item| item.is_a?(String) && !item.empty? }
        end

        def result(status, report: nil, archive_path: nil,
                   source_digest: nil, migration: nil)
          Result.new(
            status: status,
            report: report,
            archive_path: archive_path,
            source_digest: source_digest,
            migration: migration
          ).freeze
        end
      end
    end
  end
end
