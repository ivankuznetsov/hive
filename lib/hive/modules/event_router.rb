require "time"
require "hive/modules/event_ledger"

module Hive
  module Modules
    # Typed producer facade for the only autonomous module occurrences Hive
    # supports in v1. Producers persist before dispatch; replay therefore
    # reuses the stable event identity and can only yield a duplicate decision.
    class EventRouter
      def initialize(ledger:, dispatcher:, project_id:, project:, clock: -> { Time.now.utc })
        @ledger = ledger
        @dispatcher = dispatcher
        @project_id = project_id.to_s
        @project = project.to_s
        @clock = clock
      end

      def task_completed(task_id:, task_generation:, occurred_at:, payload: {})
        publish(
          event_name: "task.completed", occurred_at: occurred_at,
          source: { "type" => "task", "id" => task_id.to_s },
          idempotency_key: "task:#{task_id}:#{task_generation}:completed",
          payload: payload.merge("task_id" => task_id, "task_generation" => task_generation)
        )
      end

      def pull_request_merged(repository:, number:, merge_commit:, manifest_digest:,
                              occurred_at:, payload: {})
        publish(
          event_name: "pull_request.merged", occurred_at: occurred_at,
          source: { "type" => "github_pull_request", "id" => "#{repository}##{number}" },
          idempotency_key: "pull-request:#{repository}:#{number}:#{merge_commit}",
          payload: payload.merge(
            "repository" => repository, "number" => number, "merge_commit" => merge_commit,
            "manifest_digest" => manifest_digest
          )
        )
      end

      def project_registered(registration_id:, occurred_at:, payload: {})
        publish(
          event_name: "project.registered", occurred_at: occurred_at,
          source: { "type" => "project_registry", "id" => registration_id.to_s },
          idempotency_key: "project-registered:#{registration_id}", payload: payload
        )
      end

      def schedule(schedule:, due_at:, dispatcher_id: "daemon", missed_windows: 0, payload: {})
        instant = timestamp(due_at)
        publish(
          event_name: "schedule", occurred_at: instant,
          source: { "type" => "daemon_schedule", "id" => dispatcher_id.to_s },
          idempotency_key: "schedule:#{schedule}:#{instant}",
          payload: payload.merge(
            "schedule" => schedule, "due_at" => instant,
            "missed_windows" => Integer(missed_windows)
          )
        )
      end

      private

      def publish(event_name:, occurred_at:, source:, idempotency_key:, payload:)
        occurrence = @ledger.record(
          project_id: @project_id, project: @project, event_name: event_name,
          occurred_at: occurred_at, source: source, idempotency_key: idempotency_key,
          payload: payload, recorded_at: @clock.call
        )
        {
          occurrence: occurrence,
          decisions: @dispatcher.dispatch_event(occurrence.event)
        }
      end

      def timestamp(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6)
      rescue ArgumentError, TypeError
        raise Hive::ConfigError, "module schedule due_at must be an ISO 8601 timestamp"
      end
    end
  end
end
