require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/task_journal/envelope"
require "hive/conditions/value"

module Hive
  module TaskJournal
    class Error < Hive::Error; end
    class InvalidRecord < Error; end
    class AttemptMismatch < Error; end
    class Conflict < Error; end

    AUTHORITATIVE_EVENT_TYPES = %w[
      condition_observed
      generation_advanced
      commit_generation_advanced
      legacy_baseline
      reconciliation
      shadow_audit
      operator_action
      implementation_identity_captured
      implementation_identity_backfilled
      implementation_identity_fallback
      implementation_stage_resolved
    ].freeze
    LEGACY_ATTEMPT_ID = "legacy".freeze
    JOURNAL_BASENAME = "task-journal.jsonl".freeze
    LOCK_BASENAME = ".task-journal.lock".freeze

    AppendResult = Data.define(:cursor, :event_id, :journal_hash, :records)

    class Validator
      def initialize(attempt_store: nil, require_attempt_store: false)
        @attempt_store = attempt_store
        @require_attempt_store = require_attempt_store
        @attempt_cache = {}
        @lineage_cache = {}
      end

      def validate!(record)
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
        validate_attempt!(record)
        true
      end

      def attempt_for(attempt_id)
        @attempt_cache[attempt_id]
      end

      def lineage_for(attempt_id)
        @lineage_cache.fetch(attempt_id, []).dup
      end

      private

      def validate_attempt!(record)
        if record["attempt_id"] == LEGACY_ATTEMPT_ID
          unless record["event_type"] == "legacy_baseline" && record["task_generation"].zero?
            raise AttemptMismatch, "legacy attempt identity is valid only for a generation-0 baseline"
          end
          return
        end
        unless @attempt_store
          raise AttemptMismatch, "authoritative journal requires an attempt store" if @require_attempt_store

          return
        end

        attempt_id = record["attempt_id"]
        attempt = if @attempt_cache.key?(attempt_id)
          @attempt_cache[attempt_id]
        else
          @attempt_cache[attempt_id] = @attempt_store.fetch(attempt_id)
        end
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
        unless mismatches.empty?
          raise AttemptMismatch, "durable attempt mismatch: #{mismatches.join(', ')}"
        end

        @lineage_cache[attempt_id] ||= validate_lineage!(attempt)
      rescue Hive::Error => e
        raise AttemptMismatch, e.message
      end

      def validate_lineage!(attempt)
        expected = {
          "task_slug" => attempt["task_slug"],
          "task_id" => attempt["task_id"].to_s,
          "intended_stage" => attempt["intended_stage"],
          "task_input_epoch" => attempt.task_input_epoch
        }
        lineage = []
        seen = {}
        current = attempt
        loop do
          id = current.attempt_id
          raise AttemptMismatch, "durable attempt lineage cycle at #{id}" if seen[id]

          seen[id] = true
          lineage << current
          predecessor_id = current["predecessor_attempt_id"]
          break if predecessor_id.to_s.empty?

          predecessor = if @attempt_cache.key?(predecessor_id)
            @attempt_cache[predecessor_id]
          else
            @attempt_cache[predecessor_id] = @attempt_store.fetch(predecessor_id)
          end
          unless predecessor
            raise AttemptMismatch, "durable attempt lineage is missing predecessor #{predecessor_id}"
          end
          unless predecessor["task_slug"] == expected.fetch("task_slug") &&
                 predecessor["task_id"].to_s == expected.fetch("task_id") &&
                 predecessor["intended_stage"] == expected.fetch("intended_stage") &&
                 predecessor.task_input_epoch == expected.fetch("task_input_epoch")
            raise AttemptMismatch,
                  "durable attempt lineage predecessor #{predecessor_id} has incompatible identity"
          end
          current = predecessor
        end
        lineage.freeze
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

    class Writer
      attr_reader :task_folder, :path, :lock_path, :attempt_store

      def initialize(task_folder:, attempt_store: nil, id_generator: -> { SecureRandom.uuid },
                     clock: -> { Time.now.utc })
        @task_folder = File.expand_path(task_folder)
        @path = File.join(@task_folder, JOURNAL_BASENAME)
        @lock_path = File.join(@task_folder, LOCK_BASENAME)
        @attempt_store = attempt_store
        @validator = Validator.new(attempt_store: attempt_store, require_attempt_store: true)
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

        with_lock do
          append_records(records)
        end
      rescue Error
        raise
      rescue SystemCallError, IOError, JSON::GeneratorError => e
        raise Error, "authoritative journal append failed: #{e.class}: #{e.message}"
      end

      def append_idempotent(attributes, idempotency_key:)
        input = Envelope.stringify(attributes)
        payload = input["payload"] ||= {}
        payload["idempotency_key"] = idempotency_key.to_s
        record = Envelope.authoritative(input, id_generator: @id_generator, clock: @clock)
        validate!(record)

        with_lock do
          existing = read_records.find do |candidate|
            candidate.dig("payload", "idempotency_key") == idempotency_key.to_s
          end
          if existing
            unless idempotency_signature(existing) == idempotency_signature(record)
              raise Conflict, "conflicting authoritative event for idempotency key #{idempotency_key.inspect}"
            end

            return current_result(existing)
          end

          append_records([ record ])
        end
      rescue Error
        raise
      rescue SystemCallError, IOError, JSON::ParserError, JSON::GeneratorError => e
        raise Error, "authoritative journal append failed: #{e.class}: #{e.message}"
      end

      private

      def append_records(records)
        lines = records.map { |record| "#{JSON.generate(record)}\n" }.join
        created = !File.exist?(path) || File.zero?(path)
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644, encoding: "UTF-8") do |file|
          original_size = file.stat.size
          begin
            offset = 0
            while offset < lines.bytesize
              written = file.syswrite(lines.byteslice(offset..))
              raise IOError, "short journal append" unless written.is_a?(Integer) && written.positive?

              offset += written
            end
            file.flush
            file.fsync
          rescue SystemCallError, IOError => e
            rollback_append!(file, original_size, e)
          end
        end
        Hive::AtomicFile.fsync_directory(task_folder) if created
        current_result(records.last, records: records)
      end

      def current_result(record, records: [ record ])
        AppendResult.new(
          cursor: File.size(path),
          event_id: record.fetch("event_id"),
          journal_hash: ::Digest::SHA256.file(path).hexdigest,
          records: records.freeze
        )
      end

      def read_records
        return [] unless File.exist?(path)

        File.readlines(path, chomp: true).filter_map do |line|
          next if line.empty?

          JSON.parse(line)
        end
      end

      def idempotency_signature(record)
        payload = record.fetch("payload", {}).reject { |key, _| key == "idempotency_key" }
        canonical_json(
          "event_type" => record["event_type"],
          "task" => record["task"],
          "workflow" => record["workflow"],
          "stage" => record["stage"],
          "attempt_id" => record["attempt_id"],
          "task_generation" => record["task_generation"],
          "ownership_generation" => record["ownership_generation"],
          "commit_generation" => record["commit_generation"],
          "reason" => record["reason"],
          "evidence" => record["evidence"],
          "provenance" => record["provenance"],
          "payload" => payload
        )
      end

      def canonical_json(value)
        canonical = case value
        when Hash
          value.keys.sort.to_h { |key| [ key.to_s, JSON.parse(canonical_json(value[key])) ] }
        when Array
          value.map { |child| JSON.parse(canonical_json(child)) }
        else
          value
        end
        JSON.generate(canonical)
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

      def validate!(record)
        @validator.validate!(record)
      end

      def rollback_append!(file, original_size, original_error)
        begin
          file.truncate(original_size)
          file.flush
          file.fsync
        rescue SystemCallError, IOError => rollback_error
          raise IOError,
                "#{original_error.class}: #{original_error.message}; " \
                "journal rollback failed: #{rollback_error.class}: #{rollback_error.message}"
        end
        raise original_error
      end
    end
  end
end
