require "json"
require "digest"
require "fileutils"
require "time"
require "hive/atomic_file"
require "hive/attempts/repository"
require "hive/secret_patterns"
require "hive/task_journal"
require "hive/task_projection/store"
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
    OPERATION_SCHEMA = "hive-task-activity-operation".freeze
    OPERATION_SCHEMA_VERSION = 1
    OPERATION_DIRECTORY = "activity-operations".freeze
    MAX_OPERATION_RECEIPT_BYTES = 64 * 1024

    attr_reader :task_folder

    # Commands without an active worker context can attach activity only when
    # the canonical task projection has an exact durable attempt binding.
    # Legacy tasks deliberately return nil rather than acquiring guessed
    # authority from timestamps, markers, or process state.
    def self.for_task(task, attempt_store: nil, clock: -> { Time.now.utc })
      attempt_store ||= Hive::Attempts::Repository.open_default
      projection = Hive::TaskProjection::Store.new(
        task_folder: task.folder, attempt_store: attempt_store
      ).read.to_h
      attempt_id = projection.dig("identity", "attempt_id").to_s
      return nil if attempt_id.empty?

      attempt = attempt_store.fetch(attempt_id)
      return nil unless attempt

      workflow = task.workflow.respond_to?(:id) ? task.workflow.id : task.workflow
      new(
        task_folder: task.folder,
        task: { "id" => task.id, "slug" => task.slug },
        workflow: workflow.to_s.empty? ? "coding" : workflow.to_s,
        stage: attempt["intended_stage"],
        attempt_id: attempt_id,
        task_generation: projection.dig("identity", "task_generation"),
        ownership_generation: attempt.ownership_generation,
        commit_generation: projection.dig("identity", "commit_generation"),
        attempt_store: attempt_store, clock: clock
      )
    rescue Hive::Error, SystemCallError, IOError, JSON::ParserError
      nil
    end

    # Runtime observers already hold an authenticated durable attempt context.
    # Centralize the one default attempt-store construction here so callers
    # cannot grow alternate attempt composition roots merely to validate a
    # task-journal append.
    def self.for_context(task, context:, attempt_store: nil,
                         clock: -> { Time.now.utc })
      return nil unless context && !context.attempt_id.to_s.empty? &&
                        !context.task_generation.nil?

      attempt_store ||= Hive::Attempts::Repository.open_default
      workflow = task.respond_to?(:workflow) ? task.workflow : nil
      workflow = workflow.id if workflow.respond_to?(:id)
      new(
        task_folder: task.folder,
        task: {
          "id" => task.respond_to?(:id) ? task.id : nil,
          "slug" => task.slug
        },
        workflow: workflow.to_s.empty? ? "coding" : workflow.to_s,
        stage: context.intended_stage,
        attempt_id: context.attempt_id,
        task_generation: context.task_generation,
        ownership_generation: context.ownership_generation,
        attempt_store: attempt_store,
        clock: clock
      )
    end

    def self.fingerprint(value)
      Digest::SHA256.hexdigest(Hive::TaskWorkspace.canonical_json(value))
    end

    def self.safe_error(error)
      Hive::SecretPatterns.redact(error.message.to_s)[0, 4_096]
    end

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

    # Persist an intent before its domain mutation. Only fingerprints cross
    # this boundary: raw action tokens, prompts, notes, argv, and arbitrary
    # filesystem values are never copied into the operation ledger.
    def begin_operation(kind:, operation_id:, source:, precondition:,
                        expected_postcondition:, reason:)
      kind = kind.to_s
      raise InvalidActivity, "unknown activity kind #{kind.inspect}" unless KINDS.include?(kind)
      source = source.to_s
      raise InvalidActivity, "unknown activity source #{source.inspect}" unless SOURCE_KINDS.include?(source)

      Operation.begin!(
        activity: self,
        receipt: {
          "schema" => OPERATION_SCHEMA,
          "schema_version" => OPERATION_SCHEMA_VERSION,
          "operation_id" => required_identifier(operation_id, "operation_id"),
          "activity_kind" => kind,
          "source" => source,
          "reason" => bounded_reason(reason),
          "task" => @task,
          "workflow" => @workflow,
          "stage" => @stage,
          "attempt_id" => @attempt_id,
          "task_generation" => @task_generation,
          "ownership_generation" => @ownership_generation,
          "commit_generation" => @commit_generation,
          "precondition_fingerprint" => self.class.fingerprint(precondition),
          "expected_postcondition_fingerprint" => self.class.fingerprint(expected_postcondition),
          "state" => "pending",
          "created_at" => normalize_time(@clock.call, "created_at")
        }
      )
    end

    def binding
      {
        "task" => @task, "workflow" => @workflow, "stage" => @stage,
        "attempt_id" => @attempt_id, "task_generation" => @task_generation,
        "ownership_generation" => @ownership_generation,
        "commit_generation" => @commit_generation
      }
    end

    def relocated(task_folder:)
      self.class.new(
        task_folder: task_folder, task: @task, workflow: @workflow, stage: @stage,
        attempt_id: @attempt_id, task_generation: @task_generation,
        ownership_generation: @ownership_generation,
        commit_generation: @commit_generation,
        attempt_store: @writer.respond_to?(:attempt_store) ? @writer.attempt_store : nil,
        clock: @clock
      )
    end

    # Operation receipts survive attempt retries and stage-directory moves.
    # Reconciliation must validate a historical receipt against the durable
    # attempt binding it captured, while keeping the current task/workflow and
    # task-local writer boundary fixed.
    def activity_for_operation_receipt(receipt)
      row = receipt.to_h.transform_keys(&:to_s)
      unless self.class.canonical_equal?(row["task"], @task) &&
             self.class.canonical_equal?(row["workflow"], @workflow)
        raise InvalidActivity, "operation receipt task binding is invalid"
      end
      attempt_store = @writer.respond_to?(:attempt_store) ? @writer.attempt_store : nil
      unless attempt_store
        raise InvalidActivity, "operation receipt attempt binding is unavailable"
      end
      Hive::TaskJournal::Validator.new(
        attempt_store: attempt_store, require_attempt_store: true
      ).validate_binding!(
        task: row["task"], stage: row["stage"], attempt_id: row["attempt_id"],
        task_generation: row["task_generation"],
        ownership_generation: row["ownership_generation"]
      )

      self.class.new(
        task_folder: task_folder, task: row["task"], workflow: row["workflow"],
        stage: row["stage"], attempt_id: row["attempt_id"],
        task_generation: row["task_generation"],
        ownership_generation: row["ownership_generation"],
        commit_generation: row["commit_generation"],
        attempt_store: attempt_store,
        clock: @clock
      )
    rescue Hive::TaskJournal::Error => e
      raise InvalidActivity, Hive::SecretPatterns.redact(e.message.to_s)
    end

    def self.canonical_equal?(left, right)
      Hive::TaskWorkspace.canonical_json(left) == Hive::TaskWorkspace.canonical_json(right)
    end

    def operation_time = @clock.call
    def attempt_store = @writer.respond_to?(:attempt_store) ? @writer.attempt_store : nil

    # Reconcile bounded, task-local operation receipts. The resolver may
    # return :not_committed, :ambiguous, or a hash with status: :committed and
    # a result value/fingerprint. A pending receipt is never interpreted as a
    # successful mutation without that explicit domain check.
    def reconcile_operations!(max_receipts: 100, max_bytes: 512 * 1024, &resolver)
      raise ArgumentError, "operation reconciliation requires a resolver" unless resolver

      directory = File.join(task_folder, OPERATION_DIRECTORY)
      return { "processed" => 0, "completed" => 0, "gaps" => 0, "diagnostics" => [] } unless
        File.directory?(directory)

      entries = Dir.children(directory).grep(/\A[0-9a-f]{64}\.json\z/).sort
      diagnostics = []
      selected = []
      entries.each do |entry|
        operation = Operation.open!(activity: self, filename: entry)
        next if operation.terminal?

        selected << [ entry, operation ]
        break if selected.length > max_receipts
      rescue InvalidActivity, SystemCallError, IOError, JSON::ParserError => e
        diagnostics << {
          "source" => "task_journal", "reason" => "operation_receipt_invalid",
          "reference" => entry, "detail" => safe_error(e)
        }
      end
      if selected.length > max_receipts
        diagnostics << {
          "source" => "task_journal", "reason" => "limit_exhausted",
          "cap" => "operation_receipts", "limit" => max_receipts,
          "observed" => selected.length
        }
        selected = selected.first(max_receipts)
      end
      consumed = 0
      completed = 0
      gaps = 0
      processed = 0
      selected.each do |entry, operation|
        consumed += operation.bytes
        if consumed > max_bytes
          diagnostics << {
            "source" => "task_journal", "reason" => "limit_exhausted",
            "cap" => "operation_receipt_bytes", "limit" => max_bytes,
            "observed" => consumed
          }
          break
        end
        processed += 1

        if operation.committed?
          operation.replay!
          completed += 1
          next
        end

        verdict = resolver.call(operation.receipt.dup)
        status, result = reconciliation_verdict(verdict)
        case status
        when "committed"
          operation.complete!(result: result)
          completed += 1
        when "not_committed"
          operation.abort!(reason: "domain mutation was not committed")
        when "ambiguous"
          operation.gap!(reason: "domain mutation outcome is ambiguous")
          gaps += 1
        when "defer"
          next
        else
          raise InvalidActivity, "operation resolver returned an invalid status"
        end
      rescue InvalidActivity, SystemCallError, IOError, JSON::ParserError => e
        diagnostics << {
          "source" => "task_journal", "reason" => "operation_receipt_invalid",
          "reference" => entry, "detail" => safe_error(e)
        }
      end
      {
        "processed" => processed, "completed" => completed,
        "gaps" => gaps, "diagnostics" => diagnostics
      }
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
      raise InvalidActivity, "activity payload must be an object" unless payload.is_a?(Hash)

      activity_payload = payload.merge(
        "activity_kind" => kind,
        "operation_id" => operation_id,
        "correlation_id" => correlation_id,
        "supersedes_event_id" => supersedes_event_id
      )
      enforce_size!(activity_payload, evidence)

      result = @writer.append_idempotent(
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
      refresh_projection_checkpoint
      result
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

    # The journal remains lifecycle authority; this checkpoint only lets the
    # bounded Web reader prove that it consumed the complete authoritative
    # prefix. Refresh it after every successful append so a newly admitted
    # task does not remain permanently degraded until an unrelated projection
    # rebuild happens. A checkpoint failure cannot turn an already-durable
    # activity into a failed mutation acknowledgement.
    def refresh_projection_checkpoint
      return unless @writer.respond_to?(:attempt_store) && @writer.attempt_store

      Hive::TaskProjection::Store.new(
        task_folder: task_folder, attempt_store: @writer.attempt_store
      ).rebuild!
    rescue StandardError => e
      warn "[hive] task workspace checkpoint refresh failed: #{e.class}"
      nil
    end

    def reconciliation_verdict(value)
      if value.is_a?(Hash)
        row = value.to_h.transform_keys(&:to_s)
        [ row["status"].to_s, row.key?("result") ? row["result"] : row["result_fingerprint"] ]
      else
        [ value.to_s, nil ]
      end
    end

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
      end
    rescue ArgumentError => e
      raise InvalidActivity, safe_error(e)
    end

    def enforce_size!(payload, evidence)
      bytes = JSON.generate("payload" => payload, "evidence" => evidence).bytesize
      return if bytes <= MAX_ACTIVITY_BYTES

      raise InvalidActivity, "activity payload exceeds #{MAX_ACTIVITY_BYTES} bytes"
    end

    def safe_error(error) = Hive::TaskActivity.safe_error(error)

    public

    # One crash-recoverable operation receipt. Receipt writes use an atomic
    # owner-private file; descriptor reads reject links and path swaps.
    class Operation
      attr_reader :receipt, :bytes

      class << self
        def begin!(activity:, receipt:)
          operation = new(activity: activity, receipt: receipt)
          if File.exist?(operation.path)
            existing = open!(activity: activity, filename: File.basename(operation.path))
            if existing.receipt["state"] == "aborted"
              unless existing.same_domain_intent?(operation.receipt)
                raise Conflict, "conflicting operation receipt #{operation.operation_id}"
              end
              return begin_retry!(activity: activity, receipt: receipt)
            else
              unless existing.same_intent?(operation.receipt)
                raise Conflict, "conflicting operation receipt #{operation.operation_id}"
              end
              return existing
            end
          end
          operation.persist_new!
          operation
        end

        def begin_retry!(activity:, receipt:)
          base = receipt.fetch("operation_id")
          1.upto(100) do |number|
            candidate = "#{base}:retry:#{number}"
            path = File.join(
              activity.task_folder, OPERATION_DIRECTORY,
              "#{Digest::SHA256.hexdigest(candidate)}.json"
            )
            candidate_receipt = receipt.merge("operation_id" => candidate)
            unless File.exist?(path)
              operation = new(activity: activity, receipt: candidate_receipt)
              operation.persist_new!
              return operation
            end

            existing = open!(activity: activity, filename: File.basename(path))
            if existing.same_intent?(candidate_receipt)
              return existing unless existing.receipt["state"] == "aborted"
              next
            end
            unless existing.receipt["state"] == "aborted" &&
                   existing.same_domain_intent?(candidate_receipt)
              raise Conflict, "conflicting operation receipt #{candidate}"
            end
          end
          raise Conflict, "operation receipt retry limit exhausted"
        end

        def open!(activity:, filename:)
          unless filename.to_s.match?(/\A[0-9a-f]{64}\.json\z/)
            raise InvalidActivity, "operation receipt filename is invalid"
          end
          path = File.join(activity.task_folder, OPERATION_DIRECTORY, filename)
          stat = File.lstat(path)
          unless stat.file? && !stat.symlink? && stat.size <= MAX_OPERATION_RECEIPT_BYTES
            raise InvalidActivity, "operation receipt is not a bounded regular file"
          end
          flags = File::RDONLY
          flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
          body = File.open(path, flags) do |file|
            opened = file.stat
            unless opened.file? && opened.dev == stat.dev && opened.ino == stat.ino
              raise InvalidActivity, "operation receipt changed while opening"
            end
            file.read(MAX_OPERATION_RECEIPT_BYTES + 1)
          end
          raise InvalidActivity, "operation receipt exceeds byte limit" if
            body.bytesize > MAX_OPERATION_RECEIPT_BYTES

          receipt = JSON.parse(body)
          bound_activity = activity.activity_for_operation_receipt(receipt)
          operation = new(activity: bound_activity, receipt: receipt)
          unless File.basename(operation.path) == filename
            raise InvalidActivity, "operation receipt identity does not match filename"
          end
          operation.instance_variable_set(:@bytes, body.bytesize)
          operation
        rescue Errno::ELOOP, Errno::EMLINK
          raise InvalidActivity, "operation receipt symlink refused"
        end
      end

      def initialize(activity:, receipt:)
        @activity = activity
        @receipt = receipt.to_h.transform_keys(&:to_s)
        validate!
        @bytes = JSON.generate(@receipt).bytesize
      end

      def operation_id = receipt.fetch("operation_id")
      def complete? = receipt["state"] == "complete"
      def terminal? = %w[complete aborted gap].include?(receipt["state"])
      def committed? = receipt["state"] == "committed_pending_activity"

      def same_intent?(other)
        keys = %w[
          schema schema_version activity_kind source reason task workflow stage
          attempt_id task_generation ownership_generation commit_generation
          precondition_fingerprint expected_postcondition_fingerprint
        ]
        keys.all? do |key|
          Hive::TaskWorkspace.canonical_json(receipt[key]) ==
            Hive::TaskWorkspace.canonical_json(other[key])
        end
      end

      def same_domain_intent?(other)
        keys = %w[
          schema schema_version operation_id activity_kind source reason task
          workflow stage precondition_fingerprint expected_postcondition_fingerprint
        ]
        keys.all? do |key|
          Hive::TaskWorkspace.canonical_json(receipt[key]) ==
            Hive::TaskWorkspace.canonical_json(other[key])
        end
      end

      def complete!(result:, reason: nil, payload: {}, evidence: [], occurred_at: nil,
                    correlation_id: nil, task_folder: nil, activity: nil)
        relocate!(task_folder) if task_folder
        activity ||= @activity
        return nil if receipt["state"] == "complete" &&
          receipt["result_fingerprint"] == normalized_result_fingerprint(result)

        stable_time = normalize_time(occurred_at || @activity.operation_time)
        update!(
          "state" => "committed_pending_activity",
          "committed_at" => stable_time,
          "result_fingerprint" => normalized_result_fingerprint(result),
          "record_reason" => reason || receipt.fetch("reason"),
          "record_correlation_id" => correlation_id || operation_id,
          "record_payload" => sanitize_record_value(payload),
          "record_evidence" => sanitize_record_value(Array(evidence))
        )
        replay!(activity: activity)
      end

      def replay!(activity: @activity)
        raise InvalidActivity, "operation has no committed result" unless committed?

        result = activity.record(
          kind: receipt.fetch("activity_kind"),
          operation_id: operation_id,
          correlation_id: receipt.fetch("record_correlation_id", operation_id),
          reason: receipt.fetch("record_reason"),
          source: receipt.fetch("source"),
          occurred_at: receipt.fetch("committed_at"),
          observed_at: receipt.fetch("committed_at"),
          evidence: receipt.fetch("record_evidence", []),
          payload: receipt.fetch("record_payload", {}).merge(
            "precondition_fingerprint" => receipt.fetch("precondition_fingerprint"),
            "expected_postcondition_fingerprint" => receipt.fetch("expected_postcondition_fingerprint"),
            "result_fingerprint" => receipt.fetch("result_fingerprint")
          )
        )
        update!("state" => "complete", "event_id" => result.event_id)
        result
      end

      def reconcile!
        return false unless committed?

        replay!
        true
      end

      # A pre-v0.7.3 caller could overwrite a completed receipt before an
      # idempotent journal replay exposed the conflicting result. The journal
      # is the authoritative boundary, so reconstruct the receipt from that
      # exact event instead of deleting either durable record or inventing a
      # second event for the same operation id.
      def restore_authoritative!
        path = File.join(@activity.task_folder, Hive::TaskJournal::JOURNAL_BASENAME)
        events = Hive::TaskProjection.read_journal(
          path, attempt_store: @activity.attempt_store
        ).select do |event|
          event.dig("payload", "idempotency_key") == operation_id
        end
        unless events.length == 1 && authoritative_event_matches?(events.first)
          raise Conflict, "authoritative activity does not match operation #{operation_id}"
        end

        event = events.first
        payload = event.fetch("payload")
        update!(
          "state" => "complete",
          "event_id" => event.fetch("event_id"),
          "committed_at" => event.fetch("occurred_at"),
          "result_fingerprint" => payload.fetch("result_fingerprint"),
          "record_reason" => event.fetch("reason"),
          "record_correlation_id" => payload["correlation_id"] || operation_id,
          "record_payload" => payload.reject { |key, _| authoritative_payload_key?(key) },
          "record_evidence" => event.fetch("evidence", [])
        )
      rescue Hive::TaskProjection::Error, Hive::TaskJournal::Error, KeyError => e
        raise Conflict, "authoritative activity recovery failed: #{Hive::TaskActivity.safe_error(e)}"
      end

      def abort!(reason:)
        update!(
          "state" => "aborted", "resolved_at" => normalize_time(@activity.operation_time),
          "resolution" => bounded_text(reason)
        )
      end

      def gap!(reason:)
        stable_time = normalize_time(@activity.operation_time)
        update!(
          "state" => "committed_pending_activity",
          "activity_kind" => "activity_gap",
          "source" => "reconciliation",
          "committed_at" => stable_time,
          "result_fingerprint" => Hive::TaskActivity.fingerprint("ambiguous"),
          "record_reason" => bounded_text(reason),
          "record_payload" => { "unresolved_operation_id" => operation_id },
          "record_evidence" => []
        )
        replay!
        update!("state" => "gap")
      end

      def relocate!(folder)
        @activity = @activity.relocated(task_folder: File.expand_path(folder))
      end

      def persist_new!
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
        raise Conflict, "operation receipt already exists #{operation_id}" if File.exist?(path)
        persist!
        self
      end

      def path
        File.join(directory, "#{Digest::SHA256.hexdigest(operation_id)}.json")
      end

      private

      def authoritative_event_matches?(event)
        payload = event.fetch("payload", {})
        event["event_type"] == "activity_recorded" &&
          event["task"] == receipt["task"] &&
          event["workflow"] == receipt["workflow"] &&
          event["stage"] == receipt["stage"] &&
          event["attempt_id"] == receipt["attempt_id"] &&
          event["task_generation"] == receipt["task_generation"] &&
          event["ownership_generation"] == receipt["ownership_generation"] &&
          event["commit_generation"] == receipt["commit_generation"] &&
          event["reason"] == receipt["reason"] &&
          event.dig("provenance", "source") == receipt["source"] &&
          payload["activity_kind"] == receipt["activity_kind"] &&
          payload["operation_id"] == operation_id &&
          payload["precondition_fingerprint"] == receipt["precondition_fingerprint"] &&
          payload["expected_postcondition_fingerprint"] == receipt["expected_postcondition_fingerprint"] &&
          payload["result_fingerprint"].to_s.match?(/\A[0-9a-f]{64}\z/)
      end

      def authoritative_payload_key?(key)
        %w[
          activity_kind operation_id correlation_id supersedes_event_id idempotency_key
          precondition_fingerprint expected_postcondition_fingerprint result_fingerprint
        ].include?(key)
      end

      def directory
        File.join(@activity.task_folder, OPERATION_DIRECTORY)
      end

      def update!(attributes)
        @receipt = receipt.merge(attributes)
        validate!
        persist!
        self
      end

      def persist!
        body = "#{Hive::TaskWorkspace.canonical_json(receipt)}\n"
        raise InvalidActivity, "operation receipt exceeds byte limit" if
          body.bytesize > MAX_OPERATION_RECEIPT_BYTES

        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
        Hive::AtomicFile.write(path, body, mode: 0o600)
        File.chmod(0o600, path)
        Hive::AtomicFile.fsync_directory(directory)
        @bytes = body.bytesize
      end

      def validate!
        unless receipt["schema"] == OPERATION_SCHEMA &&
               receipt["schema_version"] == OPERATION_SCHEMA_VERSION
          raise InvalidActivity, "operation receipt schema is invalid"
        end
        unless receipt["operation_id"].to_s.match?(%r{\A[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}\z})
          raise InvalidActivity, "operation receipt id is invalid"
        end
        if receipt["record_correlation_id"] &&
           !receipt["record_correlation_id"].to_s.match?(%r{\A[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}\z})
          raise InvalidActivity, "operation receipt correlation id is invalid"
        end
        unless KINDS.include?(receipt["activity_kind"].to_s) &&
               SOURCE_KINDS.include?(receipt["source"].to_s)
          raise InvalidActivity, "operation receipt kind or source is invalid"
        end
        unless %w[pending committed_pending_activity complete aborted gap].include?(receipt["state"])
          raise InvalidActivity, "operation receipt state is invalid"
        end
        %w[precondition_fingerprint expected_postcondition_fingerprint].each do |key|
          unless receipt[key].to_s.match?(/\A[0-9a-f]{64}\z/)
            raise InvalidActivity, "operation receipt #{key} is invalid"
          end
        end
        binding = @activity.binding
        %w[task workflow stage attempt_id task_generation ownership_generation commit_generation].each do |key|
          unless Hive::TaskWorkspace.canonical_json(receipt[key]) ==
                 Hive::TaskWorkspace.canonical_json(binding[key])
            raise InvalidActivity, "operation receipt #{key} binding is invalid"
          end
        end
        Hive::TaskWorkspace.safe_value!(receipt)
      end

      def normalized_result_fingerprint(value)
        string = value.to_s
        return string if string.match?(/\A[0-9a-f]{64}\z/)

        Hive::TaskActivity.fingerprint(value)
      end

      def sanitize_record_value(value)
        Hive::TaskWorkspace.safe_value!(value)
        JSON.parse(JSON.generate(value))
      end

      def normalize_time(value)
        (value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc).iso8601(6)
      rescue ArgumentError, TypeError
        raise InvalidActivity, "operation timestamp is invalid"
      end

      def bounded_text(value)
        text = Hive::SecretPatterns.redact(value.to_s)
        raise InvalidActivity, "operation text exceeds limit" if text.bytesize > MAX_REASON_BYTES

        text
      end
    end
  end
end
