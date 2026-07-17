require "digest"
require "fileutils"
require "json"
require "time"
require "hive/task_journal/envelope"
require "hive/conditions/value"

module Hive
  module TaskJournal
    class Error < Hive::Error; end
    class InvalidRecord < Error; end
    class AttemptMismatch < Error; end

    AUTHORITATIVE_EVENT_TYPES = %w[
      condition_observed
      generation_advanced
      commit_generation_advanced
      legacy_baseline
      reconciliation
      shadow_audit
      operator_action
      scheduling_observed
    ].freeze
    LEGACY_ATTEMPT_ID = "legacy".freeze
    JOURNAL_BASENAME = "events.jsonl".freeze
    LOCK_BASENAME = ".events.lock".freeze

    AppendResult = Data.define(:cursor, :event_id, :journal_hash, :records)

    class Writer
      attr_reader :task_folder, :path, :lock_path

      def initialize(task_folder:, attempt_store: nil, id_generator: -> { SecureRandom.uuid },
                     clock: -> { Time.now.utc })
        @task_folder = File.expand_path(task_folder)
        @path = File.join(@task_folder, JOURNAL_BASENAME)
        @lock_path = File.join(@task_folder, LOCK_BASENAME)
        @attempt_store = attempt_store
        @id_generator = id_generator
        @clock = clock
      end

      def append(attributes)
        append_batch([ attributes ])
      end

      def append_batch(batch)
        raise InvalidRecord, "authoritative journal batch must not be empty" unless batch.is_a?(Array) && !batch.empty?

        records = batch.map do |attributes|
          Envelope.authoritative(attributes, id_generator: @id_generator, clock: @clock)
        end
        records.each { |record| validate!(record) }
        lines = records.map { |record| "#{JSON.generate(record)}\n" }.join

        with_lock do
          File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644, encoding: "UTF-8") do |file|
            written = file.syswrite(lines)
            raise IOError, "short journal append" unless written == lines.bytesize

            file.flush
            file.fsync
          end
          cursor = File.size(path)
          AppendResult.new(
            cursor: cursor,
            event_id: records.last.fetch("event_id"),
            journal_hash: ::Digest::SHA256.file(path).hexdigest,
            records: records.freeze
          )
        end
      rescue Error
        raise
      rescue SystemCallError, IOError, JSON::GeneratorError => e
        raise Error, "authoritative journal append failed: #{e.class}: #{e.message}"
      end

      private

      def with_lock
        FileUtils.mkdir_p(task_folder)
        File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      end

      def validate!(record)
        unless record["schema"] == Envelope::SCHEMA && record["schema_version"] == Envelope::SCHEMA_VERSION
          raise InvalidRecord, "authoritative journal record has unsupported schema"
        end
        unless AUTHORITATIVE_EVENT_TYPES.include?(record["event_type"])
          raise InvalidRecord, "unknown authoritative event_type #{record['event_type'].inspect}"
        end
        required = %w[event_id event_type occurred_at stage reason]
        required << "attempt_id" unless record["event_type"] == "scheduling_observed"
        require_non_empty!(record, required)
        validate_time!(record["occurred_at"], "occurred_at")
        validate_time!(record["observed_at"], "observed_at") if record["observed_at"]
        task = record["task"]
        unless task.is_a?(Hash) && task["slug"].is_a?(String) && !task["slug"].empty?
          raise InvalidRecord, "authoritative journal record requires task.slug"
        end
        unless record["task_generation"].is_a?(Integer) && record["task_generation"] >= 0
          raise InvalidRecord, "authoritative journal task_generation must be a non-negative integer"
        end
        if !record["commit_generation"].nil? &&
           (!record["commit_generation"].is_a?(Integer) || record["commit_generation"].negative?)
          raise InvalidRecord, "authoritative journal commit_generation must be a non-negative integer"
        end
        unless record["evidence"].is_a?(Array) && record["provenance"].is_a?(Hash) && record["payload"].is_a?(Hash)
          raise InvalidRecord, "authoritative journal evidence/provenance/payload have invalid shapes"
        end
        if record["event_type"] == "condition_observed"
          begin
            Hive::Conditions::Value.validate_observation!(record)
          rescue Hive::Conditions::InvalidCondition => e
            raise InvalidRecord, e.message
          end
        end
        validate_attempt!(record)
        true
      end

      def validate_attempt!(record)
        if record["event_type"] == "scheduling_observed" && record["attempt_id"].nil?
          return
        end
        if record["attempt_id"] == LEGACY_ATTEMPT_ID
          unless record["event_type"] == "legacy_baseline" && record["task_generation"].zero?
            raise AttemptMismatch, "legacy attempt identity is valid only for a generation-0 baseline"
          end
          return
        end
        raise AttemptMismatch, "authoritative journal requires an attempt store" unless @attempt_store

        attempt = @attempt_store.fetch(record["attempt_id"])
        raise AttemptMismatch, "unknown durable attempt #{record['attempt_id']}" unless attempt

        task = record.fetch("task")
        mismatches = []
        mismatches << "task" unless attempt["task_slug"] == task["slug"] &&
                                    (task["id"].nil? || attempt["task_id"].to_s == task["id"].to_s)
        mismatches << "stage" unless attempt["intended_stage"] == record["stage"]
        mismatches << "task_generation" unless attempt.task_input_epoch == record["task_generation"]
        if record["ownership_generation"] && attempt.ownership_generation != record["ownership_generation"]
          mismatches << "ownership_generation"
        end
        return if mismatches.empty?

        raise AttemptMismatch, "durable attempt mismatch: #{mismatches.join(', ')}"
      rescue Hive::Error => e
        raise AttemptMismatch, e.message
      end

      def require_non_empty!(record, keys)
        missing = keys.select { |key| !record[key].is_a?(String) || record[key].empty? }
        raise InvalidRecord, "authoritative journal record requires #{missing.join(', ')}" unless missing.empty?
      end

      def validate_time!(value, key)
        Time.iso8601(value)
      rescue ArgumentError, TypeError
        raise InvalidRecord, "authoritative journal #{key} must be an ISO 8601 timestamp"
      end
    end
  end
end
