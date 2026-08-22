require "json"
require "time"
require "hive/atomic_file"
require "hive/managed_directory"
require "hive/patrol_fix/projection"
require "hive/patrol_fix/task_manifest"

module Hive
  module PatrolFix
    class StageTransition
      class InvalidTransition < Hive::Error; end
      MAX_JOURNAL_BYTES = 256 * 1024
      MAX_RECORDS = 128
      RECORD_FIELDS = %w[task generation evidence_digest event from to recorded_at].freeze

      def self.with_lock(task)
        instance = new(task)
        instance.directory.with_lock(".lock") do
          instance.reconcile!
          yield instance
        end
      rescue Hive::ManagedDirectory::UnsafeError => e
        raise InvalidTransition, "patrol-fix transition store is unsafe: #{e.message}"
      end

      attr_reader :root, :lock_path, :directory
      def initialize(task)
        @task = task
        @root = File.join(task.hive_state_path, "patrol-fix", "transitions", task.slug)
        @lock_path = File.join(root, ".lock")
        @directory = Hive::ManagedDirectory.new(
          root: root, anchor: task.hive_state_path,
          label: "Patrol-fix stage transition"
        )
      end

      def begin!(destination)
        projection = Hive::PatrolFix::Projection.new(
          task_folder: @task.folder, stage: "#{@task.stage_index}-#{@task.stage_name}"
        ).to_h
        unless projection.dig("action", "kind") == "advance"
          raise InvalidTransition, "patrol-fix transition requires a current terminal stage receipt"
        end
        pending = pending_record
        values = identity.merge("event" => "intent", "from" => "#{@task.stage_index}-#{@task.stage_name}", "to" => destination)
        if pending
          raise InvalidTransition, "patrol-fix transition conflicts with a pending move" unless comparable(pending) == comparable(values)
          return pending
        end
        append(values)
      end

      def complete!(destination)
        pending = pending_record || raise(InvalidTransition, "patrol-fix transition intent is missing")
        raise InvalidTransition, "patrol-fix transition destination changed" unless pending["to"] == destination
        validate_pending_identity!(pending, folder: folder_for(destination))
        sync_stage_parents!(pending)
        append(pending.slice("task", "generation", "evidence_digest", "from", "to").merge("event" => "committed"))
      end

      def reconcile!
        pending = pending_record
        return unless pending
        current = "#{@task.stage_index}-#{@task.stage_name}"
        if pending["to"] == current
          validate_pending_identity!(pending, folder: @task.folder)
          complete!(current)
        elsif pending["from"] != current
          raise InvalidTransition, "patrol-fix transition task is outside its pending move"
        end
      end

      private

      def identity
        manifest = Hive::PatrolFix::TaskManifest.new(task_folder: @task.folder).read
        { "task" => @task.slug, "generation" => manifest.dig("task", "generation"),
          "evidence_digest" => manifest.dig("evidence_revision", "digest") }
      end

      def records
        bytes = directory.read("journal.jsonl", max_bytes: MAX_JOURNAL_BYTES, missing: true)
        return [] unless bytes
        raise InvalidTransition, "patrol-fix transition journal ends with a partial record" unless
          bytes.empty? || bytes.end_with?("\n")
        lines = bytes.lines
        raise InvalidTransition, "patrol-fix transition journal has too many records" if lines.length > MAX_RECORDS
        lines.map { |line| validate_record(JSON.parse(line)) }
      rescue JSON::ParserError => e
        raise InvalidTransition, "patrol-fix transition journal is corrupt: #{e.message}"
      end

      def pending_record
        records.reduce(nil) do |pending, row|
          if row["event"] == "intent"
            raise InvalidTransition, "patrol-fix transition journal has overlapping intents" if pending
            row
          else
            committed_as_intent = row.merge("event" => "intent")
            unless pending && comparable(pending) == comparable(committed_as_intent)
              raise InvalidTransition, "patrol-fix transition commit has no matching intent"
            end
            nil
          end
        end
      end

      def comparable(row) = row.reject { |key, _| %w[recorded_at].include?(key) }

      def append(values)
        record = values.merge("recorded_at" => Time.now.utc.iso8601)
        validate_record(record)
        body = Hive::PatrolFix.canonical_json(record)
        raise InvalidTransition, "patrol-fix transition journal is full" if records.length >= MAX_RECORDS
        previous = directory.read("journal.jsonl", max_bytes: MAX_JOURNAL_BYTES, missing: true).to_s
        bytes = previous + body
        raise InvalidTransition, "patrol-fix transition journal is oversized" if bytes.bytesize > MAX_JOURNAL_BYTES
        directory.atomic_write(
          "journal.jsonl", bytes, mode: 0o600,
          max_existing_bytes: MAX_JOURNAL_BYTES
        )
        record
      end

      def validate_record(record)
        unless record.is_a?(Hash) && record.keys.sort == RECORD_FIELDS.sort &&
               %w[intent committed].include?(record["event"]) &&
               record["task"] == @task.slug && record["generation"].is_a?(Integer) &&
               record["generation"].positive? && record["evidence_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
               Hive::PatrolFix::Projection::STAGE_DIRS.include?(record["from"]) &&
               Hive::PatrolFix::Projection::STAGE_DIRS.include?(record["to"])
          raise InvalidTransition, "patrol-fix transition journal record is invalid"
        end
        Time.iso8601(record.fetch("recorded_at"))
        record
      rescue ArgumentError, KeyError
        raise InvalidTransition, "patrol-fix transition journal timestamp is invalid"
      end

      def validate_pending_identity!(pending, folder:)
        expected = pending.slice("task", "generation", "evidence_digest")
        return if identity_for(folder) == expected

        raise InvalidTransition, "patrol-fix transition generation or evidence changed"
      end

      def identity_for(folder)
        manifest = Hive::PatrolFix::TaskManifest.new(task_folder: folder).read
        { "task" => manifest.dig("task", "slug"),
          "generation" => manifest.dig("task", "generation"),
          "evidence_digest" => manifest.dig("evidence_revision", "digest") }
      rescue Hive::PatrolFix::TaskManifest::InvalidManifest => e
        raise InvalidTransition, e.message
      end

      def folder_for(stage_dir)
        File.join(@task.hive_state_path, "stages", stage_dir, @task.slug)
      end

      def sync_stage_parents!(pending)
        [ pending.fetch("from"), pending.fetch("to") ].uniq.each do |stage_dir|
          Hive::AtomicFile.fsync_directory(
            File.join(@task.hive_state_path, "stages", stage_dir)
          )
        end
      rescue SystemCallError, IOError => e
        raise InvalidTransition, "patrol-fix stage move could not be synced: #{e.message}"
      end
    end
  end
end
