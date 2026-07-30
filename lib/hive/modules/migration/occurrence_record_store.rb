require "digest"
require "json"
require "hive/managed_directory"
require "hive/modules/migration/bounded_file_inventory"
require "hive/modules/migration/occurrence_record_validator"
require "hive/modules/migration/stable_process_lock"

module Hive
  module Modules
    module Migration
      # The sole lock/read/write owner for canonical occurrence records.
      class OccurrenceRecordStore
        include OccurrenceContract

        MAX_HISTORY_RECORDS = 4_096
        MAX_PAGE_SIZE = 256
        LOCK_STRIPES = 64
        RECORD_PATTERN = /\Aocc-[0-9a-f]{64}\.json\z/

        attr_reader :root

        def initialize(root:, validator:)
          @root = File.expand_path(root)
          @validator = validator
          @directory = Hive::ManagedDirectory.new(
            root: @root,
            label: "patrol occurrence store"
          )
          @record_locks = StableProcessLock.new(
            root: File.join(@root, ".record-locks"),
            label: "patrol occurrence record locks",
            stripes: LOCK_STRIPES
          )
        end

        def fetch(occurrence_id)
          id = @validator.occurrence_id(occurrence_id)
          with_lock(id) do
            read_record(id, missing: true)
          end
        end

        def each_record
          return enum_for(__method__) unless block_given?

          record_inventory.each_live_name(
            page_size: MAX_PAGE_SIZE
          ) do |name|
            id = File.basename(name, ".json")
            record = fetch(id)
            next unless record

            yield @validator.copy(record).freeze
          end
          nil
        end

        def retirement_candidate_if_full
          inventory = record_inventory
          snapshot = inventory.snapshot
          return nil if snapshot.count < MAX_HISTORY_RECORDS

          candidate = nil
          inventory.each_name(
            page_size: MAX_PAGE_SIZE,
            snapshot: snapshot
          ) do |name|
            id = File.basename(name, ".json")
            record = fetch(id)
            next unless record

            if retireable?(record) &&
               (!block_given? || yield(record))
              candidate = @validator.copy(record).freeze
              break
            end
          end
          unless candidate
            malformed!(
              "patrol occurrence active inventory exceeds the bounded limit"
            )
          end
          candidate
        end

        def retire!(occurrence_id)
          id = @validator.occurrence_id(occurrence_id)
          with_lock(id) do
            record = read_record(id, missing: true)
            return false unless record
            unless retireable?(record)
              malformed!(
                "patrol occurrence is not eligible for retirement"
              )
            end
            bytes = @validator.canonical(record)
            @directory.unlink(
              record_name(id),
              expected_digest: Digest::SHA256.hexdigest(bytes),
              max_bytes: MAX_RECORD_BYTES
            )
          end
        end

        def mutate(occurrence_id, create: false)
          id = @validator.occurrence_id(occurrence_id)
          with_lock(id) do
            name = record_name(id)
            original = @directory.read(
              name, max_bytes: MAX_RECORD_BYTES, missing: true
            )
            record = original && parse(original, expected_id: id)
            if record.nil? && !create
              malformed!("patrol occurrence is missing")
            end
            replacement = yield(
              record && @validator.copy(record)
            )
            @validator.validate!(replacement, expected_id: id)
            bytes = @validator.canonical(replacement)
            if bytes.bytesize > MAX_RECORD_BYTES
              malformed!(
                "patrol occurrence exceeds the bounded size"
              )
            end
            next replacement if bytes == original

            @directory.atomic_write(
              name,
              bytes,
              mode: 0o600,
              expected_digest:
                original && Digest::SHA256.hexdigest(original),
              max_existing_bytes: MAX_RECORD_BYTES
            )
            replacement
          end
        end

        private

        def read_record(occurrence_id, missing: false)
          bytes = @directory.read(
            record_name(occurrence_id),
            max_bytes: MAX_RECORD_BYTES,
            missing: missing
          )
          return nil unless bytes

          parse(bytes, expected_id: occurrence_id)
        end

        def parse(bytes, expected_id:)
          data = JSON.parse(bytes)
          unless bytes == @validator.canonical(data)
            malformed!("patrol occurrence is not canonical")
          end
          @validator.validate!(data, expected_id: expected_id)
          data.freeze
        rescue JSON::ParserError, EncodingError
          malformed!("patrol occurrence is malformed")
        end

        def record_inventory
          BoundedFileInventory.new(
            directory: @directory,
            relative: ".",
            filename_pattern: RECORD_PATTERN,
            max_entries: MAX_HISTORY_RECORDS,
            cursor_prefix: "patrol-occurrences-v1",
            malformed_message: "patrol occurrence store is malformed",
            overflow_message:
              "patrol occurrence history exceeds the bounded limit",
            missing: true,
            ignore_unmatched: true
          )
        end

        def with_lock(occurrence_id)
          # Stripe files are stable and never unlinked. A collision only
          # serializes unrelated records; it cannot transfer ownership.
          @record_locks.synchronize(
            @validator.occurrence_id(occurrence_id)
          ) { yield }
        rescue Hive::ManagedDirectory::UnsafeError,
               SystemCallError, IOError => e
          raise Hive::ConfigError,
                "patrol occurrence store is unavailable: #{e.message}"
        end

        def record_name(occurrence_id)
          "#{@validator.occurrence_id(occurrence_id)}.json"
        end

        def retireable?(record)
          record.fetch("phase") == "finalized" &&
            record.fetch("outbox").all? do |entry|
              entry.fetch("acknowledged") == true
            end
        end

        def malformed!(message)
          raise Hive::ConfigError, message
        end
      end
    end
  end
end
