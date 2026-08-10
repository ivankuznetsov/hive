require "json"
require "time"
require "hive/stringify_keys"
require "hive/task_journal/envelope"
require "hive/conditions/value"
require "hive/work_ledger"

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
            raise AttemptMismatch, "durable attempt lineage predecessor #{predecessor_id} has incompatible identity"
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
        @ledger = Hive::WorkLedger.journal(
          path: @path,
          lock_path: @lock_path,
          record_id: ->(record) { record["event_id"] }
        )
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

        append_records(records)
      rescue Error
        raise
      rescue Hive::WorkLedger::Error => e
        raise Error, "authoritative journal append failed: #{ledger_error_detail(e)}"
      rescue SystemCallError, IOError, JSON::GeneratorError => e
        raise Error, "authoritative journal append failed: #{e.class}: #{e.message}"
      end

      def append_idempotent(attributes, idempotency_key:)
        input = Hive::StringifyKeys.call(attributes)
        payload = input["payload"] ||= {}
        payload["idempotency_key"] = idempotency_key.to_s
        record = Envelope.authoritative(input, id_generator: @id_generator, clock: @clock)
        validate!(record)

        result = @ledger.append_idempotent(
          record,
          idempotency_key: idempotency_key,
          key_for: ->(candidate) { candidate.dig("payload", "idempotency_key") },
          signature_for: method(:idempotency_signature)
        )
        append_result(result)
      rescue Hive::WorkLedger::Conflict => e
        raise Conflict, e.message.sub("conflicting record", "conflicting authoritative event")
      rescue Error
        raise
      rescue Hive::WorkLedger::Error => e
        raise Error, "authoritative journal append failed: #{ledger_error_detail(e)}"
      rescue SystemCallError, IOError, JSON::ParserError, JSON::GeneratorError => e
        raise Error, "authoritative journal append failed: #{e.class}: #{e.message}"
      end

      private

      def append_records(records)
        append_result(@ledger.append(records))
      end

      def append_result(receipt)
        AppendResult.new(
          cursor: receipt.cursor,
          event_id: receipt.record_id,
          journal_hash: receipt.ledger_hash,
          records: receipt.records
        )
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

      def validate!(record)
        @validator.validate!(record)
      end

      def ledger_error_detail(error)
        cause = error.cause
        return error.message unless cause && !cause.is_a?(Hive::WorkLedger::Error)

        "#{cause.class}: #{cause.message}"
      end
    end
  end
end
