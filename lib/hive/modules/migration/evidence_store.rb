require "json"
require "hive/managed_directory"
require "hive/modules/migration/bounded_file_inventory"
require "hive/modules/migration/patrol_evidence"

module Hive
  module Modules
    module Migration
      EvidenceAppend = Data.define(:status, :record) do
        def created? = status == :created
        def duplicate? = status == :duplicate
      end
      EvidencePage = Data.define(:records, :next_cursor)
      EvidenceRepair = Data.define(:processed, :next_cursor, :complete)

      # Append-only observation for migration qualification. These bytes are
      # deliberately never consulted for effect retry or recovery decisions;
      # Patrol StateStore and RefactorPatrol JobStore remain authoritative.
      class EvidenceStore
        MAX_PAGE_SIZE = 256
        MAX_HISTORY_RECORDS = 4_096
        INDEX_SCHEMA = "hive-patrol-evidence-index".freeze
        ID_PATTERNS = {
          capture: /\Acap-[0-9a-f]{64}\z/,
          receipt: /\Areceipt-[0-9a-f]{64}\z/,
          occurrence: /\Aocc-[0-9a-f]{64}\z/,
          intent: /\Aintent-[0-9a-f]{64}\z/
        }.freeze

        attr_reader :root

        def initialize(root:)
          @root = File.expand_path(root)
          @managed_directory = Hive::ManagedDirectory.new(
            root: @root,
            label: "patrol evidence"
          )
          @managed_directory.prepare!
          %w[
            captures receipts indexes indexes/occurrences indexes/intents
          ].each { |relative| @managed_directory.ensure_directory(relative) }
        rescue Hive::ConfigError, SystemCallError => e
          raise Hive::ConfigError, "patrol evidence store is unavailable: #{e.message}"
        end

        def append_capture(capture)
          capture = capture.is_a?(PatrolCapture) ? capture : PatrolCapture.from_h(capture)
          append(captures_root, capture.capture_id, capture)
        end

        def append_receipt(receipt)
          receipt = receipt.is_a?(EffectReceipt) ? receipt : EffectReceipt.from_h(receipt)
          append(receipts_root, receipt.receipt_id, receipt)
        end

        def fetch_capture(capture_id)
          capture_id = validated_id(capture_id, :capture)
          read_record(
            File.join(captures_root, "#{capture_id}.json"),
            expected_id: capture_id,
            type: PatrolCapture
          )
        end

        def fetch_receipt(receipt_id)
          receipt_id = validated_id(receipt_id, :receipt)
          read_record(
            File.join(receipts_root, "#{receipt_id}.json"),
            expected_id: receipt_id,
            type: EffectReceipt
          )
        end

        def captures
          records(captures_root, type: PatrolCapture)
        end

        def receipts
          records(receipts_root, type: EffectReceipt)
        end

        def receipts_for_occurrence(occurrence_id, limit: MAX_PAGE_SIZE,
                                    cursor: nil)
          indexed_receipts(
            :occurrence, validated_id(occurrence_id, :occurrence),
            limit: limit, cursor: cursor
          )
        end

        def receipts_for_intent(intent_id, limit: MAX_PAGE_SIZE, cursor: nil)
          indexed_receipts(
            :intent, validated_id(intent_id, :intent),
            limit: limit, cursor: cursor
          )
        end

        # Existing stores can acquire the bounded indices without one
        # history-wide allocation. Callers persist +next_cursor+ and continue
        # in later repair ticks; an incomplete page is never presented as a
        # complete occurrence history.
        def repair_receipt_indexes(limit: MAX_PAGE_SIZE, cursor: nil)
          limit = validated_limit(limit)
          with_lock do
            paths, next_cursor = receipt_repair_page(
              limit: limit, cursor: cursor
            )
            paths.each do |path|
              receipt = read_record(
                path,
                expected_id: File.basename(path, ".json"),
                type: EffectReceipt
              )
              update_receipt_indexes_unlocked(receipt)
            end
            EvidenceRepair.new(
              processed: paths.size,
              next_cursor: next_cursor,
              complete: next_cursor.nil?
            )
          end
        end

        private

        def captures_root = File.join(root, "captures")
        def receipts_root = File.join(root, "receipts")
        def indexes_root = File.join(root, "indexes")
        def occurrence_indexes_root = File.join(indexes_root, "occurrences")
        def intent_indexes_root = File.join(indexes_root, "intents")
        def lock_path = File.join(root, "evidence.lock")

        def append(directory, identity, record)
          bytes = canonical(record.to_h)
          path = File.join(directory, "#{identity}.json")
          with_lock do
            existing = read_record(
              path,
              expected_id: identity,
              type: record.class
            )
            if existing
              unless canonical(existing.to_h) == bytes
                raise Hive::ConfigError,
                      "patrol evidence identity conflicts with existing bytes"
              end
              update_receipt_indexes_unlocked(existing) if existing.is_a?(EffectReceipt)
              return EvidenceAppend.new(status: :duplicate, record: existing)
            end

            @managed_directory.atomic_write(
              @managed_directory.relative_path(path), bytes, mode: 0o600
            )
            update_receipt_indexes_unlocked(record) if record.is_a?(EffectReceipt)
          end
          EvidenceAppend.new(status: :created, record: record)
        rescue Hive::ConfigError
          raise
        rescue SystemCallError, IOError => e
          raise Hive::ConfigError, "patrol evidence could not be appended: #{e.message}"
        end

        def records(directory, type:)
          with_lock(shared: true) do
            paths = bounded_paths(directory)
            paths.map do |path|
              identity = File.basename(path, ".json")
              read_record(path, expected_id: identity, type: type)
            end.freeze
          end
        end

        def read_record(path, expected_id:, type:)
          expected_kind = type == PatrolCapture ? :capture : :receipt
          expected_id = validated_id(expected_id, expected_kind)
          expected_directory = type == PatrolCapture ? captures_root : receipts_root
          unless File.dirname(File.expand_path(path)) == expected_directory &&
                 File.basename(path) == "#{expected_id}.json"
            raise Hive::ConfigError, "patrol evidence is malformed"
          end
          max_bytes = type == PatrolCapture ?
            PatrolEvidence::MAX_CAPTURE_BYTES :
            PatrolEvidence::MAX_RECEIPT_BYTES
          bytes = bounded_regular_read(path, max_bytes: max_bytes, missing: true)
          return nil unless bytes

          data = JSON.parse(bytes)
          raise Hive::ConfigError, "patrol evidence is malformed" unless bytes == canonical(data)

          record = type.from_h(data)
          identity = type == PatrolCapture ? record.capture_id : record.receipt_id
          raise Hive::ConfigError, "patrol evidence is malformed" unless identity == expected_id.to_s

          record
        rescue JSON::ParserError, EncodingError, TypeError, ArgumentError
          raise Hive::ConfigError, "patrol evidence is malformed"
        rescue Hive::ConfigError => e
          raise if e.message == "patrol evidence is malformed"

          raise Hive::ConfigError, "patrol evidence is malformed"
        end

        def indexed_receipts(kind, identity, limit:, cursor:)
          limit = validated_limit(limit)
          cursor = validated_optional_id(cursor, :receipt)
          with_lock(shared: true) do
            index = read_index(kind, identity)
            ids = index ? index.fetch("receipt_ids") : []
            offset = cursor ? ids.bsearch_index { |value| value > cursor } || ids.size : 0
            selected = ids.slice(offset, limit) || []
            records = selected.map do |receipt_id|
              read_record(
                File.join(receipts_root, "#{receipt_id}.json"),
                expected_id: receipt_id,
                type: EffectReceipt
              ) || raise(Hive::ConfigError, "patrol evidence is malformed")
            end.freeze
            next_cursor = ids.size > offset + selected.size ? selected.last : nil
            EvidencePage.new(records: records, next_cursor: next_cursor)
          end
        end

        def update_receipt_indexes_unlocked(receipt)
          {
            occurrence: receipt.intent.occurrence_id,
            intent: receipt.intent.intent_id
          }.each do |kind, identity|
            index = read_index(kind, identity) || {
              "schema" => INDEX_SCHEMA,
              "schema_version" => 1,
              "kind" => kind.to_s,
              "identity" => identity,
              "receipt_ids" => []
            }
            ids = (index.fetch("receipt_ids") + [ receipt.receipt_id ]).uniq.sort
            if ids.size > PatrolEvidence::MAX_EFFECTS_PER_OCCURRENCE &&
               kind == :occurrence
              raise Hive::ConfigError,
                    "patrol evidence occurrence exceeds the effect limit"
            end
            index = index.merge("receipt_ids" => ids)
            path = index_path(kind, identity)
            @managed_directory.atomic_write(
              @managed_directory.relative_path(path),
              canonical(index),
              mode: 0o600
            )
          end
        end

        def read_index(kind, identity)
          path = index_path(kind, identity)
          bytes = bounded_regular_read(
            path,
            max_bytes: PatrolEvidence::MAX_RECEIPT_BYTES,
            missing: true
          )
          return nil unless bytes

          data = JSON.parse(bytes)
          valid = bytes == canonical(data) &&
                  data.is_a?(Hash) &&
                  data.keys.sort == %w[
                    identity kind receipt_ids schema schema_version
                  ] &&
                  data["schema"] == INDEX_SCHEMA &&
                  data["schema_version"] == 1 &&
                  data["kind"] == kind.to_s &&
                  data["identity"] == identity &&
                  data["receipt_ids"].is_a?(Array) &&
                  data["receipt_ids"].uniq == data["receipt_ids"] &&
                  data["receipt_ids"].sort == data["receipt_ids"] &&
                  data["receipt_ids"].all? do |receipt_id|
                    ID_PATTERNS.fetch(:receipt).match?(receipt_id.to_s)
                  end
          raise Hive::ConfigError, "patrol evidence index is malformed" unless valid

          data
        rescue JSON::ParserError, EncodingError, TypeError
          raise Hive::ConfigError, "patrol evidence index is malformed"
        end

        def index_path(kind, identity)
          directory = case kind
          when :occurrence then occurrence_indexes_root
          when :intent then intent_indexes_root
          else raise Hive::ConfigError, "patrol evidence index is malformed"
          end
          File.join(directory, "#{identity}.json")
        end

        def validated_id(value, kind)
          string = value.to_s
          return string if ID_PATTERNS.fetch(kind).match?(string)

          raise Hive::ConfigError, "patrol evidence identity is malformed"
        end

        def validated_optional_id(value, kind)
          return nil if value.nil?

          validated_id(value, kind)
        end

        def validated_limit(value)
          limit = Integer(value)
          return limit if limit.positive? && limit <= MAX_PAGE_SIZE

          raise Hive::ConfigError, "patrol evidence page limit is malformed"
        rescue ArgumentError, TypeError
          raise Hive::ConfigError, "patrol evidence page limit is malformed"
        end

        # The inventory cursor binds a restart to one lexicographic high-water
        # mark instead of a filesystem-specific directory offset. Appends above
        # that mark are indexed by #append_receipt; mutations inside the frozen
        # inventory invalidate the cursor rather than silently skipping work.
        def receipt_repair_page(limit:, cursor:)
          page = inventory_for(
            receipts_root,
            type: :receipt,
            cursor_prefix: "repair-v2",
            malformed_message: "patrol evidence repair cursor is malformed"
          ).page(limit: limit, cursor: cursor)
          paths = page.names.map do |name|
            File.join(receipts_root, name)
          end.freeze
          [ paths, page.next_cursor ]
        end

        def bounded_paths(directory)
          kind = directory == captures_root ? :capture : :receipt
          inventory = inventory_for(
            directory,
            type: kind,
            cursor_prefix: "evidence-#{kind}-v1",
            malformed_message: "patrol evidence is malformed"
          )
          snapshot = inventory.snapshot
          inventory.each_name(
            page_size: MAX_PAGE_SIZE,
            snapshot: snapshot
          ).map do |name|
            File.join(directory, name)
          end
        end

        def inventory_for(directory, type:, cursor_prefix:, malformed_message:)
          identity_pattern = ID_PATTERNS.fetch(type)
          Hive::Modules::Migration::BoundedFileInventory.new(
            directory: @managed_directory,
            relative: @managed_directory.relative_path(directory),
            filename_pattern: /\A#{identity_pattern.source.delete_prefix('\A').delete_suffix('\z')}\.json\z/,
            max_entries: MAX_HISTORY_RECORDS,
            cursor_prefix: cursor_prefix,
            malformed_message: malformed_message,
            overflow_message:
              "patrol evidence history exceeds the bounded read limit"
          )
        end

        def bounded_regular_read(path, max_bytes:, missing: false)
          @managed_directory.read(
            @managed_directory.relative_path(path),
            max_bytes: max_bytes,
            missing: missing
          )
        rescue Hive::ConfigError
          raise Hive::ConfigError, "patrol evidence is malformed"
        end

        def with_lock(shared: false)
          @managed_directory.with_lock(
            @managed_directory.relative_path(lock_path),
            shared: shared
          ) { yield }
        rescue Hive::ManagedDirectory::UnsafeError,
               SystemCallError, IOError => e
          raise Hive::ConfigError, "patrol evidence store lock is unavailable: #{e.message}"
        end

        def canonical(value)
          PatrolEvidence.canonical(value)
        end
      end
    end
  end
end
