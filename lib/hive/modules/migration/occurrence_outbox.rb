require "digest"
require "json"
require "hive/modules/migration/occurrence_record_validator"

module Hive
  module Modules
    module Migration
      # Canonical projection-outbox operations on a record already held by
      # OccurrenceRecordStore's exclusive lock.
      class OccurrenceOutbox
        include OccurrenceContract

        def initialize(validator:)
          @validator = validator
        end

        def append(record, kind:, id:, bytes:)
          unless OUTBOX_KINDS.include?(kind)
            malformed!("patrol outbox kind is malformed")
          end
          bytes = @validator.canonical_bytes(
            bytes, "patrol outbox bytes"
          )
          digest = Digest::SHA256.hexdigest(bytes)
          existing = record.fetch("outbox").find do |entry|
            entry.fetch("kind") == kind &&
              entry.fetch("id") == id
          end
          if existing
            unless existing.fetch("bytes") == bytes &&
                   existing.fetch("digest") == digest
              malformed!("patrol outbox bytes conflict")
            end
            return existing
          end
          if record.fetch("outbox").size >= MAX_OUTBOX_ENTRIES
            malformed!("patrol outbox entry limit exceeded")
          end
          entry = {
            "sequence" => record.fetch("next_outbox_sequence"),
            "kind" => kind,
            "id" => @validator.nonempty(
              id, "patrol outbox identity"
            ),
            "digest" => digest,
            "bytes" => bytes,
            "acknowledged" => false
          }
          record["next_outbox_sequence"] += 1
          record.fetch("outbox") << entry
          entry
        end

        def append_receipt(record, cell, receipt)
          append(
            record,
            kind: "receipt",
            id: receipt.receipt_id,
            bytes: @validator.canonical(receipt.to_h)
          )
          ids = cell.fetch("receipt_ids")
          ids << receipt.receipt_id unless
            ids.include?(receipt.receipt_id)
        end

        def pending(record)
          record.fetch("outbox")
                .reject { |entry| entry.fetch("acknowledged") }
                .sort_by { |entry| entry.fetch("sequence") }
                .map { |entry| @validator.copy(entry) }
                .freeze
        end

        def acknowledge(record, entry_id:, digest:)
          id = @validator.nonempty(
            entry_id, "patrol outbox identity"
          )
          digest = @validator.nonempty(
            digest, "patrol outbox digest"
          )
          entry = record.fetch("outbox").find do |candidate|
            candidate.fetch("id") == id
          end
          malformed!("patrol outbox entry is missing") unless entry
          unless entry.fetch("digest") == digest
            malformed!(
              "patrol outbox acknowledgement conflicts"
            )
          end
          entry["acknowledged"] = true
          record
        end

        def receipt(record, receipt_id)
          id = @validator.nonempty(
            receipt_id, "patrol receipt identity"
          )
          entry = record.fetch("outbox").find do |candidate|
            candidate.fetch("kind") == "receipt" &&
              candidate.fetch("id") == id
          end
          malformed!("patrol effect receipt is missing") unless entry
          EffectReceipt.from_h(
            JSON.parse(entry.fetch("bytes"))
          )
        rescue JSON::ParserError
          malformed!("patrol effect receipt is malformed")
        end

        private

        def malformed!(message)
          raise Hive::ConfigError, message
        end
      end
    end
  end
end
