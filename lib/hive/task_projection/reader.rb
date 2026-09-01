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

      def read_routine(marker: nil) = bounded_replay(marker: marker)

      def read_bounded(marker: nil, limits: Hive::TaskWorkspace::Limits.new,
                       journal_suffix_max_bytes: nil, journal_event_limit: nil)
        byte_limit = journal_suffix_max_bytes || limits.fetch(:journal_suffix_bytes)
        event_limit = journal_event_limit || limits.fetch(:journal_events)
        bounded_replay(marker: marker, byte_limit: byte_limit, event_limit: event_limit)
      end

      private

      def bounded_replay(marker:, byte_limit: nil, event_limit: nil)
        bytes = journal_snapshot(limit: byte_limit, nonblock: true)
        records = non_empty_line_count(bytes)
        if event_limit && records > event_limit
          raise Hive::TaskProjection::InvalidJournal,
                "task journal has #{records} events (limit #{event_limit})"
        end
        receipt = Hive::TaskProjection.replay_journal(bytes)
        BoundedRead.new(
          projection: replay(receipt, marker: marker),
          state: "current",
          diagnostics: [], truncated: false,
          journal_cursor: receipt.cursor,
          journal_records: receipt.records
        )
      rescue Hive::TaskProjection::JournalLockBusy => error
        BoundedRead.new(
          projection: nil, state: "partial",
          diagnostics: [ {
            "source" => "task_journal",
            "reason" => "journal_lock_busy",
            "message" => error.message,
            "details" => {}
          } ],
          truncated: false, journal_cursor: 0, journal_records: []
        )
      rescue Hive::TaskProjection::Error, Hive::TaskJournal::Error,
             JSON::ParserError, KeyError, TypeError, ArgumentError,
             SystemCallError, IOError => error
        BoundedRead.new(
          projection: nil, state: "invalid",
          diagnostics: [ {
            "source" => "task_journal",
            "reason" => "journal_invalid",
            "message" => error.message,
            "details" => { "error_class" => error.class.name }
          } ],
          truncated: error.message.include?("limit"), journal_cursor: 0,
          journal_records: []
        )
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

      def journal_bytes(limit: nil)
        journal = open_regular(journal_path, "task journal", missing: true)
        return "" unless journal

        stat = journal.stat
        if limit && stat.size > limit
          raise Hive::TaskProjection::InvalidJournal,
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
    end
  end
end
