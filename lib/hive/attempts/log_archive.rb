require "digest"
require "time"
require "hive/attempts/stream_log"

module Hive
  module Attempts
    # Coordinates live log readers/writers while the runtime control plane
    # publishes terminal bytes through the content-addressed PayloadStore.
    class LogArchive
      Resolution = Data.define(:path, :availability)
      ReadResult = Data.define(:frames, :availability)
      ColdPage = Data.define(:attempt_ids, :cursor)
      CUSTODY_LOCK_SHARDS = 256

      def initialize(store:)
        @store = store
      end

      def hot_path(attempt_id)
        File.join(@store.logs_root, "#{safe_id(attempt_id)}.frames")
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
          record = @store.fetch(safe_id(attempt_id))
          return :missing unless record
          unless record.final?
            raise RepositoryError, "only final attempt payloads can be archived"
          end

          references = @store.seal_terminal_payloads(record)
          references.empty? ? :missing : :archived
        end
      end

      def expire(attempt_id, now: Time.now.utc)
        id = safe_id(attempt_id)
        with_custody(id, File::LOCK_EX, nonblock: true) do
          references = @store.database.transaction do |db|
            rows = db[:payload_references].where(attempt_id: id)
              .where(state: %w[sealed pinned releasable]).all
            next [] if rows.empty?

            rows.reject { |row| row.fetch(:state) == "releasable" }.each do |row|
              db[:payload_references].where(payload_id: row.fetch(:payload_id)).update(
                state: "releasable", retain_until: now.utc.iso8601(6)
              )
            end
            rows.map { |row| payload_reference(row) }.uniq
          end
          return :missing if references.empty?

          @store.payload_store.with_reference_custody(references) do
            references.each { |reference| remove_unreferenced(reference) }
          end
          @store.database.transaction do |db|
            db[:payload_references].where(attempt_id: id, state: "releasable")
              .update(retain_until: nil)
          end
          :expired
        end
      rescue Sequel::Error, RuntimeControlPlane::Error,
             SystemCallError, IOError => error
        raise RepositoryError, "attempt payload expiry failed: #{error.message}"
      end

      # SQL keyset pagination keeps maintenance bounded without rediscovering
      # content-addressed payloads through directory scans.
      def cold_attempt_ids_page(cursor:, limit:)
        limit = Integer(limit)
        raise RepositoryError, "attempt cold log page limit is invalid" unless limit.positive?

        after = normalize_cursor(cursor)
        ids = @store.database.read do |db|
          rows = expirable_logs(db)
          page = after ? rows.where { attempt_id > after } : rows
          values = page.order(:attempt_id).limit(limit).select_map(:attempt_id)
          if after && values.length < limit
            values.concat(
              rows.where { attempt_id <= after }.exclude(attempt_id: values)
                .order(:attempt_id).limit(limit - values.length).select_map(:attempt_id)
            )
          end
          values
        end
        next_cursor = { "after" => ids.last || after }.freeze
        ColdPage.new(attempt_ids: ids.freeze, cursor: next_cursor)
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        raise RepositoryError, "attempt cold log archive is unavailable: #{error.message}"
      rescue ArgumentError, TypeError
        raise RepositoryError, "attempt cold log page limit is invalid"
      end

      private

      def resolve_locked(attempt_id)
        id = safe_id(attempt_id)
        hot = hot_path(id)
        return Resolution.new(path: hot, availability: :available) if regular_status(hot)

        row = @store.database.read do |db|
          db[:payload_references].where(payload_id: payload_id(id)).first
        end
        return Resolution.new(path: nil, availability: :unavailable) unless row
        return Resolution.new(path: nil, availability: :expired) if row.fetch(:state) == "releasable"
        unless %w[sealed pinned].include?(row.fetch(:state))
          return Resolution.new(path: nil, availability: :unavailable)
        end

        reference = payload_reference(row)
        @store.payload_store.read_sealed(reference)
        Resolution.new(path: @store.payload_store.path_for(reference), availability: :available)
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        raise RepositoryError, "attempt sealed log is unreadable: #{error.message}"
      end

      def regular_status(path)
        status = File.lstat(path)
        raise RepositoryError, "attempt log is a symlink" if status.symlink?
        raise RepositoryError, "attempt log is not a regular file" unless status.file?

        status
      rescue Errno::ENOENT
        nil
      end

      def remove_unreferenced(reference)
        relative = reference.fetch("path")
        retained = @store.database.read do |db|
          db[:payload_references].where(relative_path: relative)
            .where(state: %w[sealed pinned]).any?
        end
        return if retained

        path = @store.payload_store.path_for(reference)
        status = File.lstat(path)
        raise RepositoryError, "sealed attempt payload is unsafe" unless status.file? && !status.symlink?

        File.unlink(path)
      rescue Errno::ENOENT
        nil
      end

      def normalize_cursor(cursor)
        value = cursor.to_h
        after = value.fetch("after")
        unless value.keys == [ "after" ] && (after.nil? || safe_id(after) == after)
          raise RepositoryError, "attempt cold log cursor is invalid"
        end
        after
      rescue KeyError, NoMethodError
        raise RepositoryError, "attempt cold log cursor is invalid"
      end

      def expirable_logs(db)
        db[:payload_references].where(kind: "attempt_log").where(
          Sequel.lit("state IN ('sealed', 'pinned') OR (state = 'releasable' AND retain_until IS NOT NULL)")
        )
      end

      def payload_reference(row)
        {
          "algorithm" => "sha256", "sha256" => row.fetch(:sha256),
          "size" => row.fetch(:bytes), "path" => row.fetch(:relative_path)
        }
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
        path = File.join(@store.ephemeral_locks_root, format("log-custody-%02x.lock", shard))
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        lock = File.open(path, flags, 0o600)
        entry = File.lstat(path)
        opened = lock.stat
        unless entry.file? && !entry.symlink? && opened.file? &&
               entry.dev == opened.dev && entry.ino == opened.ino
          raise RepositoryError, "attempt log custody lock is unsafe"
        end
        lock.chmod(0o600)
        acquired = lock.flock(mode | (nonblock ? File::LOCK_NB : 0))
        unless acquired
          lock.close
          return nil
        end
        lock
      rescue Errno::ELOOP
        raise RepositoryError, "attempt log custody lock is a symlink"
      rescue StandardError
        lock&.close unless lock&.closed?
        raise
      end

      def payload_id(attempt_id) = "attempt-log:#{safe_id(attempt_id)}"

      def safe_id(value)
        string = value.to_s
        return string if /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/.match?(string)

        raise RepositoryError, "unsafe attempt id"
      end
    end
  end
end
