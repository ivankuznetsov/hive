require "json"
require "time"
require "hive/secret_patterns"
require "hive/task_journal"
require "hive/task_workspace"

module Hive
  # The single append/idempotency boundary for task-local audit activity.
  # Domain services construct typed facts; TaskActivity sanitizes and binds
  # them before delegating durability to TaskJournal.
  class TaskActivity
    class Error < Hive::Error; end
    class InvalidActivity < Error; end
    class Conflict < Error; end
    class AppendFailed < Error; end

    KINDS = Hive::TaskJournal::ACTIVITY_KINDS
    SOURCE_KINDS = %w[
      attempt_dispatcher context_provenance agent_runtime stage_service
      command_service recovery_service bot_answer web_mutation open_pr review
      finalize provider_external local_git github operator reconciliation
    ].freeze
    MAX_IDENTIFIER_BYTES = 256
    MAX_REASON_BYTES = 4 * 1024
    MAX_ACTIVITY_BYTES = 64 * 1024
    MAX_EVIDENCE_ITEMS = 50

    def initialize(task_folder:, task:, workflow:, stage:, attempt_id:, task_generation:,
                   ownership_generation: nil, commit_generation: nil, writer: nil,
                   attempt_store: nil, clock: -> { Time.now.utc })
      @task_folder = File.expand_path(task_folder)
      @task = normalize_task(task)
      @workflow = required_identifier(workflow, "workflow")
      @stage = required_identifier(stage, "stage")
      @attempt_id = required_identifier(attempt_id, "attempt_id")
      @task_generation = Integer(task_generation)
      raise InvalidActivity, "task_generation must be non-negative" if @task_generation.negative?

      @ownership_generation = optional_identifier(ownership_generation, "ownership_generation")
      @commit_generation = commit_generation.nil? ? nil : Integer(commit_generation)
      if @commit_generation&.negative?
        raise InvalidActivity, "commit_generation must be non-negative"
      end
      @clock = clock
      @writer = writer || Hive::TaskJournal::Writer.new(
        task_folder: @task_folder, attempt_store: attempt_store, clock: clock
      )
    rescue ArgumentError, TypeError => e
      raise InvalidActivity, Hive::SecretPatterns.redact(e.message)
    end

    def record(kind:, operation_id:, reason:, source:, correlation_id: nil,
               occurred_at: nil, observed_at: nil, evidence: [], payload: {},
               supersedes_event_id: nil)
      kind = kind.to_s
      raise InvalidActivity, "unknown activity kind #{kind.inspect}" unless KINDS.include?(kind)

      operation_id = required_identifier(operation_id, "operation_id")
      correlation_id = optional_identifier(correlation_id, "correlation_id")
      supersedes_event_id = optional_identifier(supersedes_event_id, "supersedes_event_id")
      source = source.to_s
      raise InvalidActivity, "unknown activity source #{source.inspect}" unless SOURCE_KINDS.include?(source)

      now = @clock.call
      occurred_at = normalize_time(occurred_at || now, "occurred_at")
      observed_at = normalize_time(observed_at || now, "observed_at")
      reason = bounded_reason(reason)
      evidence = sanitize_evidence(evidence)
      payload = sanitize(payload.to_h)
      activity_payload = payload.merge(
        "activity_kind" => kind,
        "operation_id" => operation_id,
        "correlation_id" => correlation_id,
        "supersedes_event_id" => supersedes_event_id
      )
      enforce_size!(activity_payload, evidence)

      @writer.append_idempotent(
        {
          event_type: "activity_recorded",
          occurred_at: occurred_at,
          observed_at: observed_at,
          task: @task,
          workflow: @workflow,
          stage: @stage,
          attempt_id: @attempt_id,
          task_generation: @task_generation,
          ownership_generation: @ownership_generation,
          commit_generation: @commit_generation,
          reason: reason,
          evidence: evidence,
          provenance: { "source" => source, "ingested_at" => observed_at },
          payload: activity_payload
        },
        idempotency_key: operation_id
      )
    rescue Hive::TaskJournal::Conflict => e
      raise Conflict, safe_error(e)
    rescue Hive::TaskJournal::Error => e
      raise AppendFailed, safe_error(e)
    rescue InvalidActivity
      raise
    rescue JSON::GeneratorError, ArgumentError, TypeError => e
      raise InvalidActivity, safe_error(e)
    end

    private

    def normalize_task(value)
      task = value.to_h.transform_keys(&:to_s)
      slug = required_identifier(task["slug"], "task.slug")
      id = task["id"]
      unless id.nil? || id.is_a?(Integer) || id.to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,255}\z/)
        raise InvalidActivity, "task.id is invalid"
      end
      { "id" => id&.to_s, "slug" => slug }
    end

    def required_identifier(value, label)
      identifier = value.to_s
      unless identifier.match?(/\A[A-Za-z0-9][A-Za-z0-9._:\/-]*\z/) &&
             identifier.bytesize <= MAX_IDENTIFIER_BYTES
        raise InvalidActivity, "#{label} is invalid"
      end
      identifier
    end

    def optional_identifier(value, label)
      value.nil? ? nil : required_identifier(value, label)
    end

    def normalize_time(value, label)
      time = value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc
      time.iso8601(6)
    rescue ArgumentError, TypeError
      raise InvalidActivity, "#{label} must be an ISO 8601 timestamp"
    end

    def bounded_reason(value)
      reason = Hive::SecretPatterns.redact(value.to_s)
      raise InvalidActivity, "reason is required" if reason.empty?
      raise InvalidActivity, "reason exceeds #{MAX_REASON_BYTES} bytes" if reason.bytesize > MAX_REASON_BYTES

      reason
    end

    def sanitize_evidence(value)
      evidence = Array(value)
      raise InvalidActivity, "activity evidence exceeds item limit" if evidence.length > MAX_EVIDENCE_ITEMS

      sanitized = sanitize(evidence)
      unless sanitized.all? { |entry| entry.is_a?(Hash) }
        raise InvalidActivity, "activity evidence items must be objects"
      end
      sanitized
    end

    def sanitize(value)
      Hive::TaskWorkspace.safe_value!(value)
      case value
      when Hash
        value.to_h.transform_keys(&:to_s).to_h { |key, child| [ key, sanitize(child) ] }
      when Array
        value.map { |child| sanitize(child) }
      when String
        Hive::SecretPatterns.redact(value)
      when NilClass, TrueClass, FalseClass, Numeric
        value
      else
        raise InvalidActivity, "activity value #{value.class} is unsupported"
      end
    rescue ArgumentError => e
      raise InvalidActivity, safe_error(e)
    end

    def enforce_size!(payload, evidence)
      bytes = JSON.generate("payload" => payload, "evidence" => evidence).bytesize
      return if bytes <= MAX_ACTIVITY_BYTES

      raise InvalidActivity, "activity payload exceeds #{MAX_ACTIVITY_BYTES} bytes"
    end

    def safe_error(error)
      Hive::SecretPatterns.redact(error.message.to_s)[0, 4_096]
    end
  end
end
