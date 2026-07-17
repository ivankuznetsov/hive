require "securerandom"
require "time"
require "hive/daemon/retry_record"
require "hive/task_journal"
require "hive/task_projection/store"

module Hive
  module Daemon
    class RetryCoordinatorError < Hive::Error; end
    class StaleRetryGeneration < RetryCoordinatorError; end
    class StaleRetryAttempt < RetryCoordinatorError; end
    class InvalidOperatorAction < RetryCoordinatorError; end
    class RetryNotReady < RetryCoordinatorError; end

    # Sole policy owner for task-stage retry ladders and delayed dispatch
    # authorization. All durable mutations are coordinator events in the
    # generation-scoped task journal; RetryRecord is only their projection.
    class RetryCoordinator
      DEFAULT_SCHEDULE = [ 60, 60, 60, 300, 600, 3600 ].freeze
      RETRY_EVENT_TYPES = %w[
        retry_failure_scheduled retry_ready retry_dispatch_authorized
        retry_successor_claimed retry_attempt_succeeded retry_stage_reset
        retry_generation_reset retry_repaired retry_abandoned retry_rearmed
        retry_manual_requested
      ].freeze

      DispatchAuthorization = Data.define(
        :token, :project, :task_slug, :stage, :generation,
        :predecessor_attempt_id, :retry_count, :issued_at
      )

      def initialize(task_folder:, attempt_store:, schedule: DEFAULT_SCHEDULE,
                     clock: -> { Time.now.utc }, id_generator: -> { SecureRandom.uuid })
        validate_schedule!(schedule)
        @task_folder = File.expand_path(task_folder)
        @attempt_store = attempt_store
        @schedule = schedule.dup.freeze
        @clock = clock
        @id_generator = id_generator
        @writer = Hive::TaskJournal::Writer.new(
          task_folder: @task_folder, attempt_store: @attempt_store,
          clock: @clock, id_generator: @id_generator
        )
        @projection_store = Hive::TaskProjection::Store.new(
          task_folder: @task_folder, projector: Hive::TaskProjection
        )
      end

      def current
        value = @projection_store.read["retry"]
        value && RetryRecord.new(value)
      end

      def report_failure(project:, task:, workflow:, stage:, generation:, ownership_generation:,
                         attempt_id:, terminal_event_id:, failure_class:, code:, evidence:, guidance:)
        attempt = validate_failure_attempt!(
          project: project, task: task, stage: stage, generation: generation,
          ownership_generation: ownership_generation, attempt_id: attempt_id
        )
        timestamp = iso(@clock.call)
        idempotency_key = "retry-failure:#{attempt_id}:#{terminal_event_id}"
        append_computed(
          event_type: "retry_failure_scheduled", idempotency_key: idempotency_key,
          attempt: attempt, task: task, workflow: workflow, stage: stage,
          reason: code.to_s, evidence: evidence
        ) do |existing|
          if existing && existing.state == "abandoned"
            raise RetryCoordinatorError, "abandoned retry record cannot be changed by an automated failure"
          end
          if existing&.current_attempt_id && existing.current_attempt_id != attempt_id
            raise StaleRetryAttempt, "attempt #{attempt_id} no longer owns the retry record"
          end

          count = (existing&.retry_count || 0) + 1
          delay = @schedule[[ count - 1, @schedule.length - 1 ].min]
          RetryRecord.new(
            "schema" => RetryRecord::SCHEMA,
            "schema_version" => RetryRecord::SCHEMA_VERSION,
            "key" => {
              "project" => project.to_s, "task" => task.fetch("slug").to_s,
              "stage" => stage.to_s, "generation" => generation
            },
            "predecessor_attempt_id" => attempt_id,
            "current_attempt_id" => nil,
            "retry_count" => count,
            "failure_class" => failure_class.to_s,
            "failure_code" => code.to_s,
            "evidence" => evidence,
            "guidance" => guidance.to_s,
            "first_failure_at" => existing&.to_h&.fetch("first_failure_at", nil) || timestamp,
            "last_failure_at" => timestamp,
            "retry_after" => iso(@clock.call + delay),
            "state" => "cooldown",
            "authorization" => nil,
            "operator" => nil,
            "last_event_id" => terminal_event_id.to_s
          )
        end
      end

      def evaluate_due
        record = current
        return record if record&.state == "ready"
        return nil unless record&.state == "cooldown"
        return nil if @clock.call < Time.iso8601(record.to_h.fetch("retry_after"))

        transition_record(
          record, event_type: "retry_ready", reason: "deadline_elapsed",
          idempotency_key: "retry-ready:#{record.to_h.fetch('last_event_id')}:#{record.to_h.fetch('retry_after')}"
        ) do |value|
          replace(value, "state" => "ready", "retry_after" => nil, "authorization" => nil)
        end
      end

      def authorize(expected_generation:)
        record = current
        guard_generation!(record, expected_generation)
        raise RetryNotReady, "retry is still cooling down" if record.state == "cooldown"
        raise RetryNotReady, "retry is #{record.state}, not ready" unless record.state == "ready"

        existing = record.to_h["authorization"]
        return authorization_from(record, existing) if existing

        token = @id_generator.call
        issued_at = iso(@clock.call)
        updated = transition_record(
          record, event_type: "retry_dispatch_authorized", reason: "due_and_eligible",
          idempotency_key: "retry-authorization:#{record.to_h.fetch('last_event_id')}"
        ) do |value|
          replace(value, "authorization" => { "token" => token, "issued_at" => issued_at })
        end
        authorization_from(updated, updated.to_h.fetch("authorization"))
      end

      def record_success(attempt_id:, stage_transition: false, to_stage: nil)
        record = current
        raise RetryCoordinatorError, "no retry record exists" unless record
        attempt = validate_attempt_for_record!(record, attempt_id)
        return record_stage_transition(attempt_id: attempt_id, to_stage: to_stage) if stage_transition

        transition_record(
          record, event_type: "retry_attempt_succeeded", reason: "same_stage_success",
          idempotency_key: "retry-success:#{attempt_id}"
        ) do |value|
          replace(
            value, "state" => "succeeded", "retry_after" => nil,
            "current_attempt_id" => attempt.attempt_id, "authorization" => nil
          )
        end
      end

      def record_claim(authorization:, attempt_id:)
        unless authorization.is_a?(DispatchAuthorization)
          raise StaleRetryAttempt, "successor claim requires coordinator authorization"
        end
        record = current
        guard_generation!(record, authorization.generation)
        projected = record.to_h.fetch("authorization", nil)
        unless projected && projected["token"] == authorization.token &&
               authorization.predecessor_attempt_id == record.predecessor_attempt_id
          raise StaleRetryAttempt, "successor authorization is stale"
        end

        attempt = @attempt_store.fetch(attempt_id)
        key = record.key
        unless attempt&.live? && attempt["predecessor_attempt_id"] == record.predecessor_attempt_id &&
               attempt["project"] == key.fetch("project") &&
               attempt["task_slug"] == key.fetch("task") &&
               attempt["intended_stage"] == key.fetch("stage") &&
               attempt.task_input_epoch == key.fetch("generation")
          raise StaleRetryAttempt, "claimed successor does not match the retry authorization"
        end

        append_computed(
          event_type: "retry_successor_claimed",
          idempotency_key: "retry-claim:#{authorization.token}:#{attempt_id}",
          attempt: attempt, task: task_for(record), workflow: nil,
          stage: key.fetch("stage"), reason: "successor_claimed", evidence: []
        ) do |value|
          replace(
            value || record, "state" => "running", "retry_after" => nil,
            "current_attempt_id" => attempt_id
          )
        end
      end

      def record_stage_transition(attempt_id:, to_stage:)
        record = current
        raise RetryCoordinatorError, "no retry record exists" unless record
        attempt = validate_attempt_for_record!(record, attempt_id)
        append_computed(
          event_type: "retry_stage_reset", idempotency_key: "retry-stage-reset:#{attempt_id}:#{to_stage}",
          attempt: attempt, task: task_for(record), workflow: nil,
          stage: record.key.fetch("stage"), reason: "stage_transition",
          evidence: [], extra_payload: { "to_stage" => to_stage.to_s }
        ) { |_existing| nil }
      end

      def repair(expected_generation:, actor:, reason:)
        operator_transition(
          event_type: "retry_repaired", expected_generation: expected_generation,
          actor: actor, reason: reason, required_state: nil
        ) do |record, metadata|
          replace(
            record, "state" => "ready", "retry_count" => 0, "retry_after" => nil,
            "current_attempt_id" => nil, "authorization" => nil, "operator" => metadata
          )
        end
      end

      def abandon(expected_generation:, actor:, reason:)
        operator_transition(
          event_type: "retry_abandoned", expected_generation: expected_generation,
          actor: actor, reason: reason, required_state: nil
        ) do |record, metadata|
          replace(
            record, "state" => "abandoned", "retry_after" => nil,
            "current_attempt_id" => nil, "authorization" => nil, "operator" => metadata
          )
        end
      end

      def rearm(expected_generation:, actor:, reason:)
        operator_transition(
          event_type: "retry_rearmed", expected_generation: expected_generation,
          actor: actor, reason: reason, required_state: "abandoned"
        ) do |record, metadata|
          replace(
            record, "state" => "ready", "retry_count" => 0, "retry_after" => nil,
            "current_attempt_id" => nil, "authorization" => nil, "operator" => metadata
          )
        end
      end

      def manual_retry(expected_generation:)
        record = current
        guard_generation!(record, expected_generation)
        return record if record.state == "cooldown" || record.state == "abandoned"

        transition_record(
          record, event_type: "retry_manual_requested", reason: "operator_wakeup",
          idempotency_key: "retry-manual:#{record.to_h.fetch('last_event_id')}:#{iso(@clock.call)}"
        ) { |value| value }
      end

      private

      def append_computed(event_type:, idempotency_key:, attempt:, task:, workflow:, stage:,
                          reason:, evidence:, extra_payload: {})
        result = @writer.append_idempotent(idempotency_key: idempotency_key) do |records|
          existing_hash = Hive::TaskProjection.project(records: records)["retry"]
          existing = existing_hash && RetryRecord.new(existing_hash)
          replacement = yield(existing)
          {
            event_type: event_type,
            task: task,
            workflow: workflow,
            stage: stage,
            attempt_id: attempt.attempt_id,
            task_generation: attempt.task_input_epoch,
            ownership_generation: attempt.ownership_generation,
            commit_generation: nil,
            reason: reason,
            evidence: evidence,
            provenance: { "source" => "retry_coordinator" },
            payload: extra_payload.merge("retry" => replacement&.to_h)
          }
        end
        @projection_store.rebuild!
        duplicate_retry = result.record.dig("payload", "retry") if result.duplicate
        duplicate_retry ? RetryRecord.new(duplicate_retry) : current
      end

      def transition_record(record, event_type:, reason:, idempotency_key:)
        attempt = @attempt_store.fetch(record.predecessor_attempt_id)
        raise StaleRetryAttempt, "retry predecessor no longer exists" unless attempt

        append_computed(
          event_type: event_type, idempotency_key: idempotency_key,
          attempt: attempt, task: task_for(record), workflow: nil,
          stage: record.key.fetch("stage"), reason: reason, evidence: []
        ) { |current_record| yield(current_record || record) }
      end

      def operator_transition(event_type:, expected_generation:, actor:, reason:, required_state:)
        validate_operator!(actor, reason)
        record = current
        guard_generation!(record, expected_generation)
        if required_state && record.state != required_state
          raise InvalidOperatorAction, "#{event_type} requires retry state #{required_state}"
        end
        timestamp = iso(@clock.call)
        metadata = {
          "actor" => actor.to_s.strip, "reason" => reason.to_s.strip,
          "generation" => expected_generation, "at" => timestamp
        }
        transition_record(
          record, event_type: event_type, reason: reason.to_s.strip,
          idempotency_key: "#{event_type}:#{expected_generation}:#{actor}:#{reason}:#{timestamp}"
        ) { |value| yield(value, metadata) }
      end

      def validate_failure_attempt!(project:, task:, stage:, generation:, ownership_generation:, attempt_id:)
        attempt = @attempt_store.fetch(attempt_id)
        raise StaleRetryAttempt, "unknown durable attempt #{attempt_id}" unless attempt
        unless attempt.final? && attempt["project"] == project.to_s &&
               attempt["task_slug"] == task.fetch("slug").to_s &&
               attempt["intended_stage"] == stage.to_s &&
               attempt.task_input_epoch == generation &&
               attempt.ownership_generation == ownership_generation
          raise StaleRetryAttempt, "terminal attempt does not own the requested task generation"
        end
        if attempt.state == "terminal" && attempt.outcome == "succeeded"
          raise StaleRetryAttempt, "successful attempt cannot report a terminal failure"
        end
        attempt
      end

      def validate_attempt_for_record!(record, attempt_id)
        attempt = @attempt_store.fetch(attempt_id)
        raise StaleRetryAttempt, "unknown durable attempt #{attempt_id}" unless attempt
        key = record.key
        unless attempt["project"] == key.fetch("project") &&
               attempt["task_slug"] == key.fetch("task") &&
               attempt["intended_stage"] == key.fetch("stage") &&
               attempt.task_input_epoch == key.fetch("generation")
          raise StaleRetryAttempt, "attempt does not match the retry key"
        end
        attempt
      end

      def guard_generation!(record, expected)
        raise RetryCoordinatorError, "no retry record exists" unless record
        return if record.generation == expected

        raise StaleRetryGeneration,
              "retry generation is #{record.generation}, not expected generation #{expected}"
      end

      def validate_operator!(actor, reason)
        return if [ actor, reason ].all? { |value| value.is_a?(String) && !value.strip.empty? }

        raise InvalidOperatorAction, "operator action requires non-empty actor and reason"
      end

      def validate_schedule!(schedule)
        return if schedule.is_a?(Array) && !schedule.empty? &&
                  schedule.all? { |value| value.is_a?(Integer) && value.positive? }

        raise ArgumentError, "retry schedule must be a non-empty array of positive integer seconds"
      end

      def authorization_from(record, value)
        DispatchAuthorization.new(
          token: value.fetch("token"), project: record.key.fetch("project"),
          task_slug: record.key.fetch("task"), stage: record.key.fetch("stage"),
          generation: record.generation,
          predecessor_attempt_id: record.predecessor_attempt_id,
          retry_count: record.retry_count, issued_at: value.fetch("issued_at")
        )
      end

      def task_for(record)
        { "slug" => record.key.fetch("task") }
      end

      def replace(record, changes)
        RetryRecord.new(record.to_h.merge(changes))
      end

      def iso(value)
        value.utc.iso8601(6)
      end
    end
  end
end
