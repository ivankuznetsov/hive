require "digest"
require "fileutils"
require "json"
require "time"
require "hive/task_journal/envelope"
require "hive/conditions/value"
require "hive/finalization/event"

module Hive
  module TaskJournal
    class Error < Hive::Error; end
    class InvalidRecord < Error; end
    class AttemptMismatch < Error; end
    class EventIdCollision < Error; end

    AUTHORITATIVE_EVENT_TYPES = %w[
      condition_observed
      generation_advanced
      commit_generation_advanced
      legacy_baseline
      reconciliation
      shadow_audit
      operator_action
      finalized
      finalize_attempt_adopted
      babysitter_activated
      babysitter_active
      babysitter_blocked
      head_superseded
      merge_ready
      merged
      no_pr_approved
      finalization_rearmed
      archive_ready
      cleanup_completed
    ].freeze
    LEGACY_ATTEMPT_ID = "legacy".freeze
    JOURNAL_BASENAME = "events.jsonl".freeze
    LOCK_BASENAME = ".events.lock".freeze

    AppendResult = Data.define(:cursor, :event_id, :journal_hash, :records)

    class Writer
      attr_reader :task_folder, :path, :lock_path

      def initialize(task_folder:, attempt_store: nil, id_generator: -> { SecureRandom.uuid },
                     clock: -> { Time.now.utc }, authority_validator: nil)
        @task_folder = File.expand_path(task_folder)
        @path = File.join(@task_folder, JOURNAL_BASENAME)
        @lock_path = File.join(@task_folder, LOCK_BASENAME)
        @attempt_store = attempt_store
        @id_generator = id_generator
        @clock = clock
        @authority_validator = authority_validator
      end

      def append(attributes)
        append_batch([ attributes ])
      end

      def append_once(attributes)
        event_id = attributes["event_id"] || attributes[:event_id]
        unless event_id.is_a?(String) && !event_id.empty?
          raise InvalidRecord, "append_once requires a deterministic event_id"
        end
        append_records([ attributes ], once: true)
      end

      def append_batch(batch)
        raise InvalidRecord, "authoritative journal batch must not be empty" unless batch.is_a?(Array) && !batch.empty?

        append_records(batch, once: false)
      end

      private

      def append_records(batch, once:)
        records = batch.map do |attributes|
          Envelope.authoritative(attributes, id_generator: @id_generator, clock: @clock)
        end

        with_lock do
          existing = read_records_locked
          if once
            match = existing.find { |record| record["event_id"] == records.first["event_id"] }
            return append_result_for([ match ]) if match == records.first
            raise EventIdCollision, "event_id #{records.first['event_id'].inspect} has different content" if match
          end

          seen = existing.filter_map { |record| record["event_id"] }.to_h { |id| [ id, true ] }
          records.each do |record|
            raise EventIdCollision, "duplicate event_id #{record['event_id'].inspect}" if seen[record["event_id"]]

            validate!(record, records: existing)
            existing << record
            seen[record["event_id"]] = true
          end
          lines = records.map { |record| "#{JSON.generate(record)}\n" }.join
          File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644, encoding: "UTF-8") do |file|
            written = file.syswrite(lines)
            raise IOError, "short journal append" unless written == lines.bytesize

            file.flush
            file.fsync
          end
          append_result_for(records)
        end
      rescue Error
        raise
      rescue SystemCallError, IOError, JSON::GeneratorError => e
        raise Error, "authoritative journal append failed: #{e.class}: #{e.message}"
      end

      def with_lock
        FileUtils.mkdir_p(task_folder)
        File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      end

      def validate!(record, records: [])
        unless record["schema"] == Envelope::SCHEMA && record["schema_version"] == Envelope::SCHEMA_VERSION
          raise InvalidRecord, "authoritative journal record has unsupported schema"
        end
        unless AUTHORITATIVE_EVENT_TYPES.include?(record["event_type"])
          raise InvalidRecord, "unknown authoritative event_type #{record['event_type'].inspect}"
        end
        require_non_empty!(record, %w[event_id event_type occurred_at stage attempt_id reason])
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
        if Hive::Finalization::Event.finalization?(record)
          Hive::Finalization::Event.validate!(record, records: records)
          producer_kind = record.dig("producer", "kind")
          if producer_kind == "finalize_attempt"
            validate_attempt!(record)
          elsif producer_kind == "babysitter_job"
            unless @authority_validator&.respond_to?(:validate_event_authority!)
              raise AttemptMismatch, "babysitter journal event requires a job authority validator"
            end
            begin
              @authority_validator.validate_event_authority!(record)
            rescue Hive::Error => e
              raise AttemptMismatch, e.message
            end
          end
        else
          validate_attempt!(record)
        end
        true
      rescue Hive::Finalization::Error => e
        raise InvalidRecord, e.message
      end

      def read_records_locked
        return [] unless File.exist?(path)

        File.readlines(path, chomp: true).filter_map.with_index do |line, index|
          next if line.empty?

          JSON.parse(line)
        rescue JSON::ParserError => e
          raise InvalidRecord, "invalid existing journal JSON at line #{index + 1}: #{e.message}"
        end
      end

      def append_result_for(records)
        AppendResult.new(
          cursor: File.exist?(path) ? File.size(path) : 0,
          event_id: records.last.fetch("event_id"),
          journal_hash: File.exist?(path) ? ::Digest::SHA256.file(path).hexdigest : ::Digest::SHA256.hexdigest(""),
          records: records.freeze
        )
      end

      def validate_attempt!(record)
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
