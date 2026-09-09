require "digest"
require "json"
require "hive/task_journal"
require "hive/task_projection"
require "hive/task_workspace/limits"

module Hive
  class TaskProjection
    # Reads the append-only task journal and derives task state in memory.
    # There is deliberately no persisted projection, checkpoint, or repair
    # protocol: the journal is the task-history authority and the projection is
    # disposable command output.
    class Reader
      ROUTINE_CACHE_MAX_ENTRIES = 512
      ROUTINE_CACHE_MAX_SOURCE_BYTES = 64 * 1024 * 1024
      ROUTINE_CACHE = {}
      ROUTINE_CACHE_MUTEX = Mutex.new

      BoundedRead = Data.define(
        :projection, :state, :diagnostics, :truncated, :journal_cursor,
        :journal_records
      ) do
        def initialize(projection:, state:, diagnostics:, truncated:, journal_cursor:,
                       journal_records: [])
          super(
            projection: projection,
            state: state.to_s.freeze,
            diagnostics: JSON.parse(JSON.generate(diagnostics), freeze: true),
            truncated: truncated == true,
            journal_cursor: Integer(journal_cursor || 0),
            journal_records: JSON.parse(JSON.generate(journal_records), freeze: true)
          )
        end

        def current? = state == "current"
      end

      attr_reader :task_folder, :journal_path

      def initialize(task_folder:, task: nil, projector: Hive::TaskProjection)
        @task_folder = File.expand_path(task_folder)
        @journal_path = File.join(@task_folder, Hive::TaskJournal::JOURNAL_BASENAME)
        @expected_task = task
        @projector = projector
      end

      def read(marker: nil)
        replay(Hive::TaskProjection.replay_journal(journal_snapshot), marker: marker)
      end

      def read_routine(marker: nil) = bounded_replay(marker: marker, memoize: true)

      def read_bounded(marker: nil, limits: Hive::TaskWorkspace::Limits.new,
                       journal_suffix_max_bytes: nil, journal_event_limit: nil)
        byte_limit = journal_suffix_max_bytes || limits.fetch(:journal_suffix_bytes)
        event_limit = journal_event_limit || limits.fetch(:journal_events)
        bounded_replay(marker: marker, byte_limit: byte_limit, event_limit: event_limit)
      end

      private

      def bounded_replay(marker:, byte_limit: nil, event_limit: nil, memoize: false)
        cached, cache_key, bytes = if memoize
          routine_snapshot(marker)
        else
          [ nil, nil, journal_snapshot(limit: byte_limit, nonblock: true) ]
        end
        return cached if cached

        records = non_empty_line_count(bytes)
        if event_limit && records > event_limit
          raise Hive::TaskProjection::JournalTooLarge,
                "task journal has #{records} events (limit #{event_limit})"
        end
        receipt = Hive::TaskProjection.replay_journal(bytes)
        result = BoundedRead.new(
          projection: replay(receipt, marker: marker),
          state: "current",
          diagnostics: [], truncated: false,
          journal_cursor: receipt.cursor,
          journal_records: receipt.records
        )
        routine_cache_store(cache_key, result) if cache_key
        result
      rescue Hive::TaskProjection::JournalLockBusy => error
        BoundedRead.new(
          projection: nil, state: "busy",
          diagnostics: [ {
            "source" => "task_journal",
            "reason" => "journal_lock_busy",
            "message" => error.message,
            "details" => {}
          } ],
          truncated: false, journal_cursor: 0, journal_records: []
        )
      rescue Hive::TaskProjection::JournalTooLarge => error
        invalid_read(error, truncated: true, cache_key: cache_key)
      rescue Hive::TaskProjection::Error, Hive::TaskJournal::Error,
             JSON::ParserError, KeyError, TypeError, ArgumentError,
             SystemCallError, IOError => error
        invalid_read(error, truncated: false, cache_key: cache_key)
      end

      def invalid_read(error, truncated:, cache_key: nil)
        result = BoundedRead.new(
          projection: nil, state: "invalid",
          diagnostics: [ {
            "source" => "task_journal",
            "reason" => "journal_invalid",
            "message" => error.message,
            "details" => { "error_class" => error.class.name }
          } ],
          truncated: truncated, journal_cursor: 0, journal_records: []
        )
        routine_cache_store(cache_key, result) if cache_key
        result
      end

      def replay(receipt, marker:)
        validate_expected_task!(receipt.records)
        @projector.project(
          records: receipt.records, cursor: receipt.cursor,
          journal_hash: receipt.ledger_hash, marker: marker
        )
      end

      def non_empty_line_count(bytes) = bytes.each_line.count { |line| !line.strip.empty? }

      def journal_snapshot(limit: nil, nonblock: false)
        with_read_lock(nonblock: nonblock) { journal_bytes(limit: limit) }
      end

      def routine_snapshot(marker)
        with_read_lock(nonblock: true) do
          journal = open_regular(journal_path, "task journal", missing: true)
          identity = journal ? file_identity(journal.stat) : [ :missing ].freeze
          cache_key = routine_cache_key(identity, marker)
          cached = routine_cache_fetch(cache_key)
          [ cached, cache_key, cached ? nil : journal&.read.to_s ]
        ensure
          journal&.close
        end
      end

      def journal_bytes(limit: nil)
        journal = open_regular(journal_path, "task journal", missing: true)
        return "" unless journal

        stat = journal.stat
        if limit && stat.size > limit
          raise Hive::TaskProjection::JournalTooLarge,
                "task journal is #{stat.size} bytes (limit #{limit})"
        end

        journal.read
      ensure
        journal&.close
      end

      def with_read_lock(nonblock: false)
        lock = open_regular(lock_path, "task journal lock", missing: true)
        unless lock
          result = yield
          return result unless lock_path_present?

          return with_read_lock(nonblock: nonblock) { yield }
        end

        mode = File::LOCK_SH
        mode |= File::LOCK_NB if nonblock
        unless lock.flock(mode)
          raise Hive::TaskProjection::JournalLockBusy,
                "task journal writer holds the task lock"
        end
        yield
      ensure
        lock&.flock(File::LOCK_UN)
        lock&.close
      end

      def validate_expected_task!(records)
        return unless @expected_task&.respond_to?(:slug)

        workflow = @expected_task.respond_to?(:workflow) ? @expected_task.workflow : nil
        expected = {
          "slug" => @expected_task.slug.to_s,
          "id" => @expected_task.respond_to?(:id) ? @expected_task.id&.to_s : nil,
          "workflow" => workflow.respond_to?(:id) ? workflow.id.to_s : nil
        }
        mismatch = records.any? do |record|
          task = record.fetch("task")
          task["slug"].to_s != expected.fetch("slug") ||
            (!expected["id"].to_s.empty? && task["id"].to_s != expected.fetch("id")) ||
            (!expected["workflow"].to_s.empty? &&
             record["workflow"].to_s != expected.fetch("workflow"))
        end
        if mismatch
          raise Hive::TaskProjection::InvalidJournal,
                "task journal contains records for a different task"
        end
      end

      def routine_cache_key(identity, marker)
        [
          journal_path.dup.freeze,
          identity,
          marker_identity(marker),
          expected_task_identity,
          @projector.object_id
        ].freeze
      end

      def marker_identity(marker)
        return nil unless marker

        value = {
          "name" => marker.respond_to?(:name) ? marker.name.to_s : marker.fetch("name").to_s,
          "attrs" => Hive::StringifyKeys.call(
            marker.respond_to?(:attrs) ? marker.attrs : marker.fetch("attrs", {})
          )
        }
        Digest::SHA256.hexdigest(Hive::TaskProjection.canonical_json(value)).freeze
      end

      def expected_task_identity
        return nil unless @expected_task&.respond_to?(:slug)

        workflow = @expected_task.respond_to?(:workflow) ? @expected_task.workflow : nil
        [
          @expected_task.slug.to_s,
          @expected_task.respond_to?(:id) ? @expected_task.id&.to_s : nil,
          workflow.respond_to?(:id) ? workflow.id.to_s : nil
        ].freeze
      end

      def file_identity(stat)
        [
          stat.dev, stat.ino, stat.size,
          stat.mtime.to_i, stat.mtime.nsec,
          stat.ctime.to_i, stat.ctime.nsec
        ].freeze
      end

      def routine_cache_fetch(key)
        ROUTINE_CACHE_MUTEX.synchronize do
          cached = ROUTINE_CACHE.delete(key)
          ROUTINE_CACHE[key] = cached if cached
          cached
        end
      end

      def routine_cache_store(key, result)
        ROUTINE_CACHE_MUTEX.synchronize do
          ROUTINE_CACHE.delete_if do |cached_key, _|
            cached_key[0] == key[0] && cached_key[1] != key[1]
          end
          ROUTINE_CACHE.delete(key)
          ROUTINE_CACHE[key] = result
          while ROUTINE_CACHE.size > ROUTINE_CACHE_MAX_ENTRIES ||
                routine_cache_source_bytes > ROUTINE_CACHE_MAX_SOURCE_BYTES
            ROUTINE_CACHE.shift
          end
        end
      end

      def routine_cache_source_bytes
        ROUTINE_CACHE.sum { |cache_key, _| cache_key[1][2].to_i }
      end

      def lock_path_present?
        File.lstat(lock_path)
        true
      rescue Errno::ENOENT
        false
      end

      def open_regular(path, label, missing:)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        file = File.open(path, flags)
        return file if file.stat.file?

        file.close
        raise Hive::TaskProjection::InvalidJournal, "#{label} is not a regular file"
      rescue Errno::ENOENT
        raise unless missing

        nil
      rescue Errno::ELOOP
        raise Hive::TaskProjection::InvalidJournal, "#{label} is not a regular file"
      end

      def lock_path = File.join(task_folder, Hive::TaskJournal::LOCK_BASENAME)

      private_constant :ROUTINE_CACHE, :ROUTINE_CACHE_MUTEX
    end
  end
end
