require "fileutils"
require "json"
require "hive/atomic_file"
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
        REPAIR_CURSOR = /\Arepair-v1-([0-9a-f]+)-([0-9a-f]+)-([0-9a-f]+)\z/
        ID_PATTERNS = {
          capture: /\Acap-[0-9a-f]{64}\z/,
          receipt: /\Areceipt-[0-9a-f]{64}\z/,
          occurrence: /\Aocc-[0-9a-f]{64}\z/,
          intent: /\Aintent-[0-9a-f]{64}\z/
        }.freeze

        attr_reader :root

        def initialize(root:)
          @root = File.expand_path(root)
          prepare_directory(captures_root)
          prepare_directory(receipts_root)
          prepare_directory(indexes_root)
          prepare_directory(occurrence_indexes_root)
          prepare_directory(intent_indexes_root)
        rescue SystemCallError => e
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

        def prepare_directory(path)
          FileUtils.mkdir_p(path, mode: 0o700)
          File.chmod(0o700, path)
        end

        def append(directory, identity, record)
          bytes = canonical(record.to_h)
          path = File.join(directory, "#{identity}.json")
          with_lock do
            if File.file?(path)
              existing = read_record(
                path,
                expected_id: identity,
                type: record.class
              )
              unless canonical(existing.to_h) == bytes
                raise Hive::ConfigError,
                      "patrol evidence identity conflicts with existing bytes"
              end
              update_receipt_indexes_unlocked(existing) if existing.is_a?(EffectReceipt)
              return EvidenceAppend.new(status: :duplicate, record: existing)
            end

            Hive::AtomicFile.write(path, bytes, mode: 0o600)
            Hive::AtomicFile.fsync_directory(directory)
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
            paths = bounded_paths(
              directory, limit: MAX_HISTORY_RECORDS + 1, cursor: nil
            )
            if paths.size > MAX_HISTORY_RECORDS
              raise Hive::ConfigError,
                    "patrol evidence history exceeds the bounded read limit"
            end
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
          bytes = bounded_regular_read(path, max_bytes: max_bytes)
          data = JSON.parse(bytes)
          raise Hive::ConfigError, "patrol evidence is malformed" unless bytes == canonical(data)

          record = type.from_h(data)
          identity = type == PatrolCapture ? record.capture_id : record.receipt_id
          raise Hive::ConfigError, "patrol evidence is malformed" unless identity == expected_id.to_s

          record
        rescue Errno::ENOENT
          nil
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
            Hive::AtomicFile.write(path, canonical(index), mode: 0o600)
            Hive::AtomicFile.fsync_directory(File.dirname(path))
          end
        end

        def read_index(kind, identity)
          path = index_path(kind, identity)
          bytes = bounded_regular_read(
            path, max_bytes: PatrolEvidence::MAX_RECEIPT_BYTES
          )
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
        rescue Errno::ENOENT
          nil
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

        # Directory positions are opaque filesystem cookies, so the cursor is
        # bound to the exact receipt directory device/inode that issued it.
        # Receipt files are append-only: additions between pages are already
        # indexed by #append_receipt and cannot invalidate repair of the older
        # files. Each call reads at most +limit + 1+ directory entries and at
        # most +limit+ receipt documents; no history-wide name allocation or
        # rescan hides behind the paged API.
        def receipt_repair_page(limit:, cursor:)
          directory = File.lstat(receipts_root)
          unless directory.directory? && !directory.symlink?
            raise Hive::ConfigError, "patrol evidence is malformed"
          end
          offset = repair_offset(
            cursor, device: directory.dev, inode: directory.ino
          )
          paths = []
          next_cursor = nil
          Dir.open(receipts_root) do |entries|
            entries.seek(offset) if offset
            skip_directory_pseudo_entries(entries) unless offset
            limit.times do
              name = entries.read
              break unless name

              paths << receipt_repair_path(name)
            end
            position = entries.tell
            if entries.read
              next_cursor = repair_cursor(
                device: directory.dev, inode: directory.ino,
                offset: position
              )
            end
          end
          [ paths.freeze, next_cursor ]
        rescue Hive::ConfigError
          raise
        rescue SystemCallError, IOError, ArgumentError
          raise Hive::ConfigError, "patrol evidence repair cursor is malformed"
        end

        def skip_directory_pseudo_entries(entries)
          %w[. ..].each do |expected|
            observed = entries.read
            unless observed == expected
              raise Hive::ConfigError, "patrol evidence is malformed"
            end
          end
        end

        def receipt_repair_path(name)
          identity = name.to_s.delete_suffix(".json")
          unless name == "#{identity}.json" &&
                 ID_PATTERNS.fetch(:receipt).match?(identity)
            raise Hive::ConfigError, "patrol evidence is malformed"
          end
          File.join(receipts_root, name)
        end

        def repair_cursor(device:, inode:, offset:)
          "repair-v1-#{Integer(device).to_s(16)}-" \
            "#{Integer(inode).to_s(16)}-#{Integer(offset).to_s(16)}"
        end

        def repair_offset(cursor, device:, inode:)
          return nil if cursor.nil?

          match = REPAIR_CURSOR.match(cursor.to_s)
          unless match &&
                 Integer(match[1], 16) == device &&
                 Integer(match[2], 16) == inode
            raise Hive::ConfigError,
                  "patrol evidence repair cursor is malformed"
          end
          offset = Integer(match[3], 16)
          unless offset.positive? && offset <= (2**63 - 1)
            raise Hive::ConfigError,
                  "patrol evidence repair cursor is malformed"
          end
          offset
        rescue ArgumentError, TypeError
          raise Hive::ConfigError,
                "patrol evidence repair cursor is malformed"
        end

        def bounded_paths(directory, limit:, cursor:)
          names = []
          Dir.each_child(directory) do |name|
            next unless name.end_with?(".json")
            identity = name.delete_suffix(".json")
            next if cursor && identity <= cursor

            names << name
            if names.size > MAX_HISTORY_RECORDS + 1
              raise Hive::ConfigError,
                    "patrol evidence history exceeds the bounded read limit"
            end
          end
          names.sort.first(limit).map { |name| File.join(directory, name) }
        rescue SystemCallError
          raise Hive::ConfigError, "patrol evidence is malformed"
        end

        def bounded_regular_read(path, max_bytes:)
          before = File.lstat(path)
          unless before.file? && !before.symlink? && before.size <= max_bytes
            raise Hive::ConfigError, "patrol evidence is malformed"
          end
          flags = File::RDONLY
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          File.open(path, flags) do |io|
            current = io.stat
            unless current.file? && current.dev == before.dev &&
                   current.ino == before.ino
              raise Hive::ConfigError, "patrol evidence is malformed"
            end
            bytes = io.read(max_bytes + 1)
            if bytes.nil? || bytes.bytesize > max_bytes
              raise Hive::ConfigError, "patrol evidence is malformed"
            end
            bytes
          end
        end

        def with_lock(shared: false)
          File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(shared ? File::LOCK_SH : File::LOCK_EX)
            yield
          ensure
            lock&.flock(File::LOCK_UN)
          end
        rescue SystemCallError, IOError => e
          raise Hive::ConfigError, "patrol evidence store lock is unavailable: #{e.message}"
        end

        def canonical(value)
          PatrolEvidence.canonical(value)
        end
      end
    end
  end
end
