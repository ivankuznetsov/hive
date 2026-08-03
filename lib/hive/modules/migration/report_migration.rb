require "json"
require "hive/modules/migration/report"
require "hive/modules/migration/report_projection"

module Hive
  module Modules
    module Migration
      module ReportMigration
        ARCHIVE_NAME = "report.v1.archive.json".freeze
        RECEIPT_NAME = "report.migration.json".freeze
        RECEIPT_SCHEMA = "hive-module-migration-report-migration".freeze
        RECEIPT_KEYS = %w[
          archive_digest archive_name migrated_at output_digest report_id schema
          schema_version source_digest source_name
        ].freeze
        MAX_RECEIPT_BYTES = 16 * 1024

        module_function

        def required?(path)
          Report.with_locked_storage(path, shared: true) do |storage|
            required_locked?(storage)
          end
        end

        def required_locked?(storage)
          bytes = Report.read_locked(storage, missing: true)
          return false unless bytes

          payload = canonical_payload(bytes)
          version = payload["schema_version"]
          if version == 1 && Report.valid_legacy_payload?(payload)
            true
          elsif version == 2
            projection = ReportProjection.from_h(payload)
            migration_provenance_required?(storage, projection, bytes)
          else
            malformed!
          end
        end

        def forward(path:, qualifications:, generated_at:)
          Report.with_locked_storage(path) do |storage|
            forward_locked(
              storage: storage,
              qualifications: qualifications,
              generated_at: generated_at
            )
          end
        end

        def forward_locked(storage:, qualifications:, generated_at:)
          bytes = Report.read_locked(storage, missing: true)
          return nil unless bytes

          payload = canonical_payload(bytes)
          if payload["schema_version"] == 2
            projection = ReportProjection.from_h(payload)
            ensure_receipt_locked(storage, projection, bytes) if
              projection.migration
            return projection
          end
          malformed! unless Report.valid_legacy_payload?(payload)

          source_digest = Report.digest_bytes(bytes)
          archive = Report.read_locked(
            storage, name: ARCHIVE_NAME, missing: true
          )
          if archive
            malformed! unless Report.digest_bytes(archive) == source_digest &&
                              archive == bytes
          else
            Report.write_locked(
              storage, bytes, name: ARCHIVE_NAME,
              max_existing_bytes: Report::MAX_REPORT_BYTES
            )
            archive = bytes
          end
          archive_digest = Report.digest_bytes(archive)
          qualifications = Array(qualifications)
          projection = ReportProjection.build(
            qualifications: qualifications,
            generated_at: generated_at,
            migration: {
              "source_schema_version" => 1,
              "source_digest" => source_digest,
              "archive_digest" => archive_digest,
              "disposition" =>
                qualifications.empty? ? "evidence_required" : "projected"
            }
          )
          output = Report.canonical(projection.to_h)
          Report.write_locked(
            storage, output, expected_digest: source_digest
          )
          persist_receipt_locked(
            storage,
            source_digest: source_digest,
            archive_digest: archive_digest,
            output_digest: Report.digest_bytes(output),
            report_id: projection.report_id,
            migrated_at: projection.generated_at
          )
          projection
        end

        def reverse(path:, expected_digest:)
          expected_digest = hex_digest(expected_digest)
          Report.with_locked_storage(path) do |storage|
            current = Report.read_locked(storage)
            malformed! unless Report.digest_bytes(current) == expected_digest
            projection = ReportProjection.from_h(canonical_payload(current))
            malformed! unless projection.migration
            archive, archive_digest = verified_archive_locked(
              storage, projection.migration
            )
            receipt = read_receipt_locked(storage)
            validate_receipt_linkage!(
              storage, receipt, projection, current, archive_digest
            )
            Report.write_locked(
              storage, archive, expected_digest: expected_digest
            )
          end
          path
        end

        def ensure_receipt_locked(storage, projection, output)
          _, archive_digest = verified_archive_locked(
            storage, projection.migration
          )
          receipt = Report.read_locked(
            storage, name: RECEIPT_NAME,
            max_bytes: MAX_RECEIPT_BYTES, missing: true
          )
          if receipt
            parsed = parse_receipt(receipt)
            validate_receipt_linkage!(
              storage, parsed, projection, output, archive_digest
            )
            return parsed
          end

          malformed! if projection.supersedes

          persist_receipt_locked(
            storage,
            source_digest: projection.migration.fetch("source_digest"),
            archive_digest: archive_digest,
            output_digest: Report.digest_bytes(output),
            report_id: projection.report_id,
            migrated_at: projection.generated_at
          )
        end
        private_class_method :ensure_receipt_locked

        def persist_receipt_locked(storage, source_digest:, archive_digest:,
                                   output_digest:, report_id:, migrated_at:)
          payload = {
            "schema" => RECEIPT_SCHEMA,
            "schema_version" => 1,
            "source_name" => storage.filename,
            "archive_name" => ARCHIVE_NAME,
            "source_digest" => source_digest,
            "archive_digest" => archive_digest,
            "output_digest" => output_digest,
            "report_id" => report_id,
            "migrated_at" => migrated_at
          }
          bytes = Report.canonical(payload)
          existing = Report.read_locked(
            storage, name: RECEIPT_NAME,
            max_bytes: MAX_RECEIPT_BYTES, missing: true
          )
          if existing
            parsed = parse_receipt(existing)
            malformed! unless parsed.fetch("source_name") == storage.filename &&
                              parsed.fetch("source_digest") == source_digest &&
                              parsed.fetch("archive_digest") == archive_digest
            return parsed
          end
          Report.write_locked(
            storage, bytes, name: RECEIPT_NAME,
            max_existing_bytes: MAX_RECEIPT_BYTES
          )
          payload.freeze
        end
        private_class_method :persist_receipt_locked

        def read_receipt_locked(storage)
          parse_receipt(
            Report.read_locked(
              storage, name: RECEIPT_NAME, max_bytes: MAX_RECEIPT_BYTES
            )
          )
        end
        private_class_method :read_receipt_locked

        def migration_provenance_required?(storage, projection, output)
          return false unless projection.migration

          _, archive_digest = verified_archive_locked(
            storage, projection.migration
          )
          receipt = Report.read_locked(
            storage, name: RECEIPT_NAME,
            max_bytes: MAX_RECEIPT_BYTES, missing: true
          )
          unless receipt
            malformed! if projection.supersedes
            return true
          end

          validate_receipt_linkage!(
            storage, parse_receipt(receipt), projection, output, archive_digest
          )
          false
        end
        private_class_method :migration_provenance_required?

        def verified_archive_locked(storage, migration)
          archive = Report.read_locked(storage, name: ARCHIVE_NAME)
          archive_payload = canonical_payload(archive)
          malformed! unless Report.valid_legacy_payload?(archive_payload)
          archive_digest = Report.digest_bytes(archive)
          malformed! unless migration.fetch("source_digest") == archive_digest &&
                            migration.fetch("archive_digest") == archive_digest
          [ archive, archive_digest ]
        end
        private_class_method :verified_archive_locked

        def validate_receipt_linkage!(storage, receipt, projection, output,
                                      archive_digest)
          migration = projection.migration
          malformed! unless receipt.fetch("source_name") == storage.filename &&
                            receipt.fetch("source_digest") == archive_digest &&
                            receipt.fetch("archive_digest") == archive_digest &&
                            migration.fetch("source_digest") == archive_digest &&
                            migration.fetch("archive_digest") == archive_digest
          if receipt.fetch("report_id") == projection.report_id
            malformed! unless receipt.fetch("output_digest") ==
                              Report.digest_bytes(output)
          end
          receipt
        end
        private_class_method :validate_receipt_linkage!

        def parse_receipt(bytes)
          value = canonical_payload(bytes)
          PatrolEvidence.exact_keys!(
            value, RECEIPT_KEYS, label: "module migration report migration"
          )
          malformed! unless value["schema"] == RECEIPT_SCHEMA &&
                            value["schema_version"] == 1 &&
                            value["archive_name"] == ARCHIVE_NAME &&
                            value["source_name"].is_a?(String) &&
                            value["report_id"].to_s.match?(
                              /\Areport-[0-9a-f]{64}\z/
                            )
          %w[source_digest archive_digest output_digest].each do |key|
            hex_digest(value.fetch(key))
          end
          PatrolEvidence.timestamp(
            value["migrated_at"],
            label: "module migration report migration"
          )
          value.freeze
        end
        private_class_method :parse_receipt

        def canonical_payload(bytes)
          value = JSON.parse(bytes)
          malformed! unless value.is_a?(Hash) &&
                            bytes == Report.canonical(value)
          value
        rescue JSON::ParserError, EncodingError
          malformed!
        end
        private_class_method :canonical_payload

        def hex_digest(value)
          string = value.to_s
          malformed! unless string.match?(/\A[0-9a-f]{64}\z/)
          string
        end
        private_class_method :hex_digest

        def malformed!
          raise Hive::ConfigError,
                "module migration report migration is malformed"
        end
        private_class_method :malformed!
      end
    end
  end
end
