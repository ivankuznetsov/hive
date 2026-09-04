require "json"
require "time"
require "hive/canonical_json"
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

    ACTIVITY_KINDS = %w[
      attempt_admitted
      context_launch_captured
      context_selection_reported
      session_started
      session_finished
      usage_observed
      resource_limit_observed
      stage_transition
      question_asked
      answer_recorded
      approval_recorded
      rejection_recorded
      decision_recorded
      retry_requested
      recovery_recorded
      hold_recorded
      context_revision
      commit_observed
      push_observed
      pr_observed
      check_observed
      merge_observed
      operator_action
      correction
      activity_gap
    ].freeze

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
      implementation_identity_observed
      implementation_stage_resolved
      activity_recorded
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
        @stream_task = nil
        @stream_task_id = nil
        @stream_attempts = {}
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
        validate_activity!(record) if record["event_type"] == "activity_recorded"
        validate_attempt!(record)
        validate_stream_binding!(record)
        true
      end

      def validate_binding!(task:, stage:, attempt_id:, task_generation:,
                            ownership_generation: nil)
        validate_attempt!(
          "task" => Hive::StringifyKeys.call(task),
          "stage" => stage.to_s,
          "attempt_id" => attempt_id.to_s,
          "task_generation" => Integer(task_generation),
          "ownership_generation" => ownership_generation
        )
        true
      rescue ArgumentError, TypeError => e
        raise AttemptMismatch, e.message
      end

      private

      def validate_stream_binding!(record)
        task = record.fetch("task")
        stream_task = [ task.fetch("slug"), record["workflow"].to_s ]
        if @stream_task && @stream_task != stream_task
          raise AttemptMismatch, "task journal mixes task or workflow identities"
        end
        @stream_task ||= stream_task

        task_id = task["id"].to_s
        if !task_id.empty? && @stream_task_id && @stream_task_id != task_id
          raise AttemptMismatch, "task journal mixes task IDs"
        end
        @stream_task_id ||= task_id unless task_id.empty?

        attempt_id = record.fetch("attempt_id")
        binding = [
          record.fetch("stage"), record.fetch("task_generation"),
          record["ownership_generation"]
        ]
        existing = @stream_attempts[attempt_id]
        if existing && existing != binding
          raise AttemptMismatch, "task journal attempt #{attempt_id} changes identity"
        end
        @stream_attempts[attempt_id] ||= binding
      end

      def validate_activity!(record)
        payload = record.fetch("payload")
        kind = payload["activity_kind"]
        unless ACTIVITY_KINDS.include?(kind)
          raise InvalidRecord, "authoritative activity has invalid activity_kind"
        end
        require_identifier!(payload["operation_id"], "operation_id")
        require_identifier!(payload["correlation_id"], "correlation_id") if payload["correlation_id"]
        if payload["supersedes_event_id"]
          require_identifier!(payload["supersedes_event_id"], "supersedes_event_id")
        end
        source = record.dig("provenance", "source")
        require_identifier!(source, "provenance.source")
      end

      def require_identifier!(value, label)
        unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,255}\z/)
          raise InvalidRecord, "authoritative activity #{label} is invalid"
        end
      end

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
          @attempt_cache[attempt_id] = fetch_attempt(attempt_id)
        end
        raise AttemptMismatch, "unknown durable attempt #{record['attempt_id']}" unless attempt

        task = record.fetch("task")
        mismatches = []
        mismatches << "task" unless attempt["task_slug"] == task["slug"] &&
                                    (task["id"].nil? || attempt["task_id"].to_s == task["id"].to_s)
        mismatches << "stage" unless attempt["intended_stage"] == record["stage"]
        mismatches << "task_generation" unless
          attempt_value(attempt, :task_input_epoch) == record["task_generation"]
        if record["ownership_generation"] &&
           attempt_value(attempt, :ownership_generation) != record["ownership_generation"]
          mismatches << "ownership_generation"
        end
        unless mismatches.empty?
          raise AttemptMismatch, "durable attempt mismatch: #{mismatches.join(', ')}"
        end

      rescue Hive::Error => e
        raise AttemptMismatch, e.message
      end

      def fetch_attempt(attempt_id)
        @attempt_store.fetch(attempt_id)
      end

      def attempt_value(attempt, name)
        attempt.respond_to?(name) ? attempt.public_send(name) : attempt[name.to_s]
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
        Hive::CanonicalJSON.generate(
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
