require "digest"
require "json"
require "time"
require "hive/atomic_file"
require "hive/attempts/point_storage"
require "hive/attempts/stream_log"

module Hive
  module Attempts
    # Stable attempt-ID resolver for active and cold framed logs. Writers and
    # readers hold shared custody; movement and deletion require a nonblocking
    # exclusive lock, so maintenance never races a final drain or live writer.
    class LogArchive
      Resolution = Data.define(:path, :availability)
      ReadResult = Data.define(:frames, :availability)
      STATE_KIND = "attempt".freeze
      STATE_SCHEMA = "hive-attempt-log-state".freeze
      MAX_STATE_BYTES = 16 * 1024
      CUSTODY_LOCK_SHARDS = 256

      def initialize(store:)
        @store = store
        @state = PointStorage.new(
          root: store.log_state_root,
          label: "attempt log state",
          create_directories: true
        )
      end

      def hot_path(attempt_id)
        File.join(@store.logs_root, "#{safe_id(attempt_id)}.frames")
      end

      def cold_path(attempt_id)
        File.join(@store.cold_logs_root, "#{safe_id(attempt_id)}.frames")
      end

      def open_writer(attempt_id, clock: -> { Time.now.utc })
        lock = open_custody(attempt_id, File::LOCK_SH)
        StreamLog.new(hot_path(attempt_id), clock: clock, custody_io: lock)
      rescue StandardError
        lock&.close unless lock&.closed?
        raise
      end

      def resolve(attempt_id)
        with_custody(attempt_id, File::LOCK_SH) { resolve_locked(attempt_id) }
      end

      def read(attempt_id, after_sequence: 0)
        with_reader(attempt_id) do |path, availability|
          frames = path ? StreamLog.read(path, after_sequence: after_sequence) : []
          ReadResult.new(frames: frames, availability: availability)
        end
      end

      def with_reader(attempt_id)
        with_custody(attempt_id, File::LOCK_SH) do
          resolution = resolve_locked(attempt_id)
          yield resolution.path, resolution.availability
        end
      end

      def archive(attempt_id)
        with_custody(attempt_id, File::LOCK_EX, nonblock: true) do
          hot = hot_path(attempt_id)
          cold = cold_path(attempt_id)
          hot_status = regular_status(hot)
          cold_status = regular_status(cold)
          return :archived if hot_status.nil? && cold_status
          return :missing unless hot_status
          if cold_status
            unless Digest::SHA256.file(hot).digest == Digest::SHA256.file(cold).digest
              raise StoreError, "attempt hot and cold logs conflict"
            end
            File.unlink(hot)
          else
            File.rename(hot, cold)
            File.chmod(0o600, cold)
          end
          Hive::AtomicFile.fsync_directory(@store.logs_root)
          Hive::AtomicFile.fsync_directory(@store.cold_logs_root)
          :archived
        end
      end

      def expire(attempt_id, now: Time.now.utc)
        with_custody(attempt_id, File::LOCK_EX, nonblock: true) do
          id = safe_id(attempt_id)
          write_expired(id, now: now)
          [ hot_path(id), cold_path(id) ].each do |path|
            File.unlink(path) if regular_status(path)
          end
          Hive::AtomicFile.fsync_directory(@store.logs_root)
          Hive::AtomicFile.fsync_directory(@store.cold_logs_root)
          :expired
        end
      end

      def each_cold_attempt_id
        return enum_for(__method__) unless block_given?

        Dir.each_child(@store.cold_logs_root) do |entry|
          next unless entry.end_with?(".frames")

          attempt_id = entry.delete_suffix(".frames")
          next unless safe_id(attempt_id) == attempt_id
          next unless regular_status(File.join(@store.cold_logs_root, entry))

          yield attempt_id
        rescue StoreError
          next
        end
      rescue SystemCallError, IOError => error
        raise StoreError, "attempt cold log archive is unavailable: #{error.message}"
      end

      private

      def resolve_locked(attempt_id)
        hot = hot_path(attempt_id)
        return Resolution.new(path: hot, availability: :available) if regular_status(hot)

        cold = cold_path(attempt_id)
        return Resolution.new(path: cold, availability: :available) if regular_status(cold)

        availability = expired?(attempt_id) ? :expired : :unavailable
        Resolution.new(path: nil, availability: availability)
      end

      def regular_status(path)
        status = File.lstat(path)
        raise StoreError, "attempt log is a symlink" if status.symlink?
        raise StoreError, "attempt log is not a regular file" unless status.file?

        status
      rescue Errno::ENOENT
        nil
      end

      def with_custody(attempt_id, mode, nonblock: false)
        lock = open_custody(attempt_id, mode, nonblock: nonblock)
        return :busy unless lock

        yield
      ensure
        if lock && !lock.closed?
          lock.flock(File::LOCK_UN)
          lock.close
        end
      end

      def open_custody(attempt_id, mode, nonblock: false)
        id = safe_id(attempt_id)
        digest = Digest::SHA256.hexdigest(id)
        shard = digest[0, 2].to_i(16) % CUSTODY_LOCK_SHARDS
        path = File.join(
          @store.generation_locks_root,
          format("log-custody-%02x.lock", shard)
        )
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        lock = File.open(path, flags, 0o600)
        entry = File.lstat(path)
        opened = lock.stat
        unless entry.file? && !entry.symlink? && opened.file? &&
               entry.dev == opened.dev && entry.ino == opened.ino
          raise StoreError, "attempt log custody lock is unsafe"
        end
        lock.chmod(0o600)
        acquired = lock.flock(mode | (nonblock ? File::LOCK_NB : 0))
        unless acquired
          lock.close
          return nil
        end
        lock
      rescue Errno::ELOOP
        raise StoreError, "attempt log custody lock is a symlink"
      rescue StandardError
        lock&.close unless lock&.closed?
        raise
      end

      def write_expired(attempt_id, now:)
        key = state_key(attempt_id)
        @state.synchronize(STATE_KIND, key) do
          current = @state.read(STATE_KIND, key, max_bytes: MAX_STATE_BYTES)
          payload = {
            "schema" => STATE_SCHEMA,
            "schema_version" => 1,
            "attempt_id" => attempt_id,
            "status" => "expired",
            "expired_at" => now.utc.iso8601(6)
          }
          bytes = StorageKey.dump(payload)
          @state.write(
            STATE_KIND, key, bytes,
            expected_bytes: current, max_existing_bytes: MAX_STATE_BYTES
          ) unless current == bytes
        end
      end

      def expired?(attempt_id)
        key = state_key(safe_id(attempt_id))
        bytes = @state.read(STATE_KIND, key, max_bytes: MAX_STATE_BYTES)
        return false unless bytes

        data = JSON.parse(bytes)
        valid = data.is_a?(Hash) &&
          data["schema"] == STATE_SCHEMA &&
          data["schema_version"] == 1 &&
          data["attempt_id"] == safe_id(attempt_id) &&
          data["status"] == "expired" &&
          bytes == StorageKey.dump(data)
        raise StoreError, "attempt log state is corrupt or colliding" unless valid

        true
      rescue JSON::ParserError, ArgumentError, TypeError
        raise StoreError, "attempt log state is corrupt or colliding"
      end

      def state_key(attempt_id) = { "attempt_id" => attempt_id }

      def safe_id(value)
        string = value.to_s
        return string if /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/.match?(string)

        raise StoreError, "unsafe attempt id"
      end
    end
  end
end
