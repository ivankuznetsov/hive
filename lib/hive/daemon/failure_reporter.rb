require "hive/config"
require "hive/markers"
require "hive/task_resolver"
require "hive/terminal_error_registry"
require "hive/daemon/retry_coordinator"

module Hive
  module Daemon
    # Injected terminal-outcome port. Producers submit facts and diagnostics;
    # this boundary sanitizes them and delegates all policy to RetryCoordinator.
    class FailureReporter
      def initialize(attempt_store:, registry: Hive::TerminalErrorRegistry,
                     task_resolver: nil, coordinator_factory: nil,
                     global_daemon: nil)
        @attempt_store = attempt_store
        @registry = registry
        @task_resolver = task_resolver || method(:resolve_task)
        @coordinator_factory = coordinator_factory
        @global_daemon = global_daemon
        @coordinators = {}
      end

      def observe(attempt, code: nil, failure_class: nil, payload: {})
        raise ArgumentError, "terminal failure reporter requires a final attempt" unless attempt&.final?

        task = @task_resolver.call(attempt)
        raise Hive::Error, "cannot resolve task for attempt #{attempt.attempt_id}" unless task

        if attempt.state == "terminal" && attempt.outcome == "succeeded"
          return observe_success(task, attempt)
        end

        marker = current_marker(task)
        raw_code = code || code_for(attempt, marker)
        diagnostic_payload = {
          "source" => attempt.state == "lost" ? "attempt_loss" : "terminal_receipt",
          "attempt_id" => attempt.attempt_id,
          "exit_status" => attempt.receipt&.fetch("exit_status", nil),
          "reason" => raw_code,
          "provider" => attempt["provider"],
          "marker" => marker && { "name" => marker.name.to_s, "attrs" => marker.attrs.to_h },
          "diagnostics" => attempt["diagnostics"],
          "reported" => payload
        }.compact
        diagnosis = @registry.diagnose(code: raw_code, payload: diagnostic_payload)
        coordinator = coordinator_for(task, attempt)
        coordinator.report_failure(
          project: attempt["project"],
          task: { "id" => attempt["task_id"], "slug" => attempt["task_slug"] },
          workflow: workflow_id(task), stage: attempt["intended_stage"],
          generation: attempt.task_input_epoch,
          ownership_generation: attempt.ownership_generation,
          attempt_id: attempt.attempt_id,
          terminal_event_id: terminal_event_id(attempt),
          failure_class: (failure_class || raw_code).to_s,
          code: diagnosis.fetch("code"), evidence: diagnosis.fetch("evidence"),
          guidance: diagnosis.fetch("guidance")
        )
      end

      private

      def observe_success(task, attempt)
        coordinator = coordinator_for(task, attempt)
        record = coordinator.current
        return nil unless record
        return record unless [ record.current_attempt_id, record.predecessor_attempt_id ].include?(attempt.attempt_id)

        current_stage = "#{task.stage_index}-#{task.stage_name}"
        coordinator.record_success(
          attempt_id: attempt.attempt_id,
          stage_transition: current_stage != attempt["intended_stage"],
          to_stage: current_stage
        )
      end

      def code_for(attempt, marker)
        return "agent_died" if attempt.state == "lost"
        return "timeout" if attempt.receipt&.fetch("exit_status", nil) == 124

        reason = marker&.attrs&.to_h&.fetch("reason", nil)
        reason.to_s.empty? ? "unknown" : reason
      end

      def terminal_event_id(attempt)
        if attempt.state == "lost"
          "loss:#{attempt.attempt_id}:#{attempt['loss']['at']}"
        else
          "terminal:#{attempt.attempt_id}:#{attempt.receipt.fetch('ended_at')}"
        end
      end

      def current_marker(task)
        marker = Hive::Markers.current(task.state_file)
        marker.none? ? nil : marker
      rescue SystemCallError, ArgumentError
        nil
      end

      def coordinator_for(task, attempt)
        return @coordinator_factory.call(task, attempt) if @coordinator_factory

        @coordinators[task.folder] ||= begin
          cfg = Hive::Config.load(task.project_root)
          schedule = Hive::Config.retry_backoff(cfg, global_daemon: @global_daemon)
          RetryCoordinator.new(
            task_folder: task.folder, attempt_store: @attempt_store, schedule: schedule
          )
        end
      end

      def resolve_task(attempt)
        target = attempt["task_id"].to_s.empty? ? attempt["task_slug"] : attempt["task_id"]
        Hive::TaskResolver.new(target, project_filter: attempt["project"]).resolve
      rescue Hive::Error, SystemCallError
        nil
      end

      def workflow_id(task)
        workflow = task.workflow
        workflow.respond_to?(:id) ? workflow.id : workflow.to_s
      end
    end
  end
end
