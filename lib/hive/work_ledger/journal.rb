require "digest"
require "fileutils"
require "json"
require "hive/atomic_file"

module Hive
  module WorkLedger
    # Crash-conscious JSONL append mechanics. Record shape and identity are
    # injected by the caller; Journal owns locking, complete writes, fsync,
    # rollback, and idempotency-key conflict detection.
    class Journal
      attr_reader :path, :lock_path

      def initialize(path:, lock_path:, record_id:)
        unless path.is_a?(String) && !path.empty?
          raise InvalidRequest, "path must be a non-empty string"
        end
        unless lock_path.is_a?(String) && !lock_path.empty?
          raise InvalidRequest, "lock_path must be a non-empty string"
        end

        @path = File.expand_path(path)
        @lock_path = File.expand_path(lock_path)
        @directory = File.dirname(@path)
        @record_id = record_id
        unless @record_id.respond_to?(:call)
          raise InvalidRequest, "record_id must be callable"
        end
      end

      def append(records)
        record_ids = validate_batch!(records)
        synchronize { append_unlocked(records, record_id: record_ids.last) }
      rescue Error
        raise
      rescue StandardError => e
        raise AppendFailed, "ledger append failed: #{e.class}: #{e.message}"
      end

      def append_idempotent(record, idempotency_key:, key_for:, signature_for:)
        record_id = validate_batch!([ record ]).first
        validate_callable!(key_for, "key_for")
        validate_callable!(signature_for, "signature_for")
        key = idempotency_key.to_s

        synchronize do
          existing = read_records_unlocked.find { |candidate| key_for.call(candidate) == key }
          if existing
            unless signature_for.call(existing) == signature_for.call(record)
              raise Conflict, "conflicting record for idempotency key #{idempotency_key.inspect}"
            end

            return current_receipt(
              record_id: validated_record_id(existing),
              records: [ existing ]
            )
          end

          append_unlocked([ record ], record_id: record_id)
        end
      rescue Error
        raise
      rescue StandardError => e
        raise AppendFailed, "ledger append failed: #{e.class}: #{e.message}"
      end

      private

      def validate_batch!(records)
        unless records.is_a?(Array) && !records.empty?
          raise InvalidRequest, "ledger append batch must not be empty"
        end

        records.map do |record|
          id = @record_id.call(record)
          unless id.is_a?(String) && !id.empty?
            raise InvalidRecord, "ledger record identity must be a non-empty string"
          end
          id
        end
      rescue KeyError, TypeError => e
        raise InvalidRecord, "ledger record identity is invalid: #{e.message}"
      end

      def validate_callable!(callable, label)
        return if callable.respond_to?(:call)

        raise InvalidRequest, "#{label} must be callable"
      end

      def synchronize
        FileUtils.mkdir_p(@directory)
        FileUtils.mkdir_p(File.dirname(lock_path))
        File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      end

      def append_unlocked(records, record_id:)
        lines = records.map { |record| "#{JSON.generate(record)}\n" }.join
        created = !File.exist?(path) || File.zero?(path)
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644, encoding: "UTF-8") do |file|
          original_size = file.stat.size
          begin
            write_all(file, lines)
            file.flush
            file.fsync
          rescue SystemCallError, IOError => e
            rollback_append!(file, original_size, e)
          end
        end
        Hive::AtomicFile.fsync_directory(@directory) if created
        current_receipt(record_id: record_id, records: records)
      end

      def write_all(file, bytes)
        offset = 0
        while offset < bytes.bytesize
          written = file.syswrite(bytes.byteslice(offset..))
          raise IOError, "short ledger append" unless written.is_a?(Integer) && written.positive?

          offset += written
        end
      end

      def rollback_append!(file, original_size, original_error)
        begin
          file.truncate(original_size)
          file.flush
          file.fsync
        rescue SystemCallError, IOError => rollback_error
          raise IOError,
                "#{original_error.class}: #{original_error.message}; " \
                "ledger rollback failed: #{rollback_error.class}: #{rollback_error.message}"
        end
        raise original_error
      end

      def read_records_unlocked
        return [] unless File.exist?(path)

        File.readlines(path, chomp: true).filter_map do |line|
          next if line.empty?

          JSON.parse(line)
        end
      end

      def validated_record_id(record)
        id = @record_id.call(record)
        return id if id.is_a?(String) && !id.empty?

        raise InvalidRecord, "ledger record identity must be a non-empty string"
      end

      def current_receipt(record_id:, records:)
        AppendReceipt.new(
          cursor: File.size(path),
          record_id: record_id,
          ledger_hash: ::Digest::SHA256.file(path).hexdigest,
          records: records.dup.freeze
        )
      end
    end
  end
end
