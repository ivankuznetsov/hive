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

      # Append-only observation for migration qualification. These bytes are
      # deliberately never consulted for effect retry or recovery decisions;
      # Patrol StateStore and RefactorPatrol JobStore remain authoritative.
      class EvidenceStore
        attr_reader :root

        def initialize(root:)
          @root = File.expand_path(root)
          prepare_directory(captures_root)
          prepare_directory(receipts_root)
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
          read_record(
            File.join(captures_root, "#{capture_id}.json"),
            expected_id: capture_id,
            type: PatrolCapture
          )
        end

        def fetch_receipt(receipt_id)
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

        private

        def captures_root = File.join(root, "captures")
        def receipts_root = File.join(root, "receipts")
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
              return EvidenceAppend.new(status: :duplicate, record: existing)
            end

            Hive::AtomicFile.write(path, bytes, mode: 0o600)
            Hive::AtomicFile.fsync_directory(directory)
          end
          EvidenceAppend.new(status: :created, record: record)
        rescue Hive::ConfigError
          raise
        rescue SystemCallError, IOError => e
          raise Hive::ConfigError, "patrol evidence could not be appended: #{e.message}"
        end

        def records(directory, type:)
          with_lock(shared: true) do
            Dir.glob(File.join(directory, "*.json")).sort.map do |path|
              identity = File.basename(path, ".json")
              read_record(path, expected_id: identity, type: type)
            end.freeze
          end
        end

        def read_record(path, expected_id:, type:)
          bytes = File.binread(path)
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
