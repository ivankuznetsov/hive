module Hive
  module SchedulingProof
    module Reason
      ALL = %w[
        executing needs_input edit_debounce dependency_wait admission_error
        retry_wait cooldown quarantined legacy_policy_exhausted
        provider_circuit_open provider_unavailable global_capacity project_capacity
        daily_capacity merge_wait babysitter_blocked archive_guard project_dropped
        terminal_error abandoned dispatch_pending dispatch_failed markerless_stalled
        already_in_flight eligible_not_dispatched no_candidate daemon_not_running
        daemon_stale live_evidence_unavailable accounting_inconsistent
      ].freeze

      ALIASES = {
        "dispatch" => "dispatch_pending",
        "wait_for_answers" => "needs_input",
        "record_baseline" => "needs_input",
        "wait_for_debounce" => "edit_debounce",
        "blocked_on_dependency" => "dependency_wait",
        "dependency_unmet" => "dependency_wait",
        "global_cap" => "global_capacity",
        "project_cap" => "project_capacity",
        "daily_cap" => "daily_capacity",
        "cooldown" => "cooldown",
        "quarantined" => "quarantined",
        "project_dropped" => "project_dropped",
        "poll_for_merge" => "merge_wait",
        "markerless_stalled" => "markerless_stalled",
        "in_flight" => "already_in_flight",
        "error" => "terminal_error",
        "recover_execute" => "terminal_error",
        "recover_review" => "terminal_error",
        "skip" => "eligible_not_dispatched"
      }.freeze

      SUMMARIES = {
        "executing" => "A current task attempt is running and owns capacity.",
        "needs_input" => "The task is waiting for operator input.",
        "edit_debounce" => "Recent input is settling before the task can resume.",
        "dependency_wait" => "A dependency gate is holding this task.",
        "admission_error" => "Dependency admission is invalid and fails closed.",
        "retry_wait" => "The task is waiting for its retry window.",
        "cooldown" => "The task is in scheduler cooldown.",
        "quarantined" => "Automatic dispatch is quarantined after repeated failures.",
        "legacy_policy_exhausted" => "A legacy recovery policy is exhausted.",
        "provider_circuit_open" => "The selected provider or model circuit is open.",
        "provider_unavailable" => "No provider route is currently available.",
        "global_capacity" => "All configured task capacity is in use.",
        "project_capacity" => "This project has reached its task capacity.",
        "daily_capacity" => "This project has reached its daily task limit.",
        "merge_wait" => "The task is waiting for the current pull request to merge.",
        "babysitter_blocked" => "The current babysitter job is blocked.",
        "archive_guard" => "Current-generation archive evidence is not yet satisfied.",
        "project_dropped" => "The daemon dropped this project after a configuration failure.",
        "terminal_error" => "The current generation ended in an error that needs attention.",
        "abandoned" => "The task is visible but has been abandoned.",
        "dispatch_pending" => "The task was eligible and dispatch acceptance is pending.",
        "dispatch_failed" => "The scheduler could not accept the eligible task.",
        "markerless_stalled" => "The last run exited without recording stage progress.",
        "already_in_flight" => "This task already has an in-flight dispatch.",
        "eligible_not_dispatched" => "The task was eligible but no attempt was accepted.",
        "no_candidate" => "No enrolled task can use this capacity.",
        "daemon_not_running" => "The task daemon is not running; live scheduling claims are unavailable.",
        "daemon_stale" => "The daemon heartbeat is stale; live scheduling claims are unavailable.",
        "live_evidence_unavailable" => "Live scheduling evidence is unavailable.",
        "accounting_inconsistent" => "Task-capacity evidence is inconsistent; scheduling advice is suppressed."
      }.freeze

      module_function

      def normalize(value)
        candidate = value.to_s
        return candidate if ALL.include?(candidate)

        ALIASES.fetch(candidate, "live_evidence_unavailable")
      end

      def valid?(value)
        ALL.include?(value.to_s)
      end

      def summary(value)
        SUMMARIES.fetch(normalize(value))
      end
    end
  end
end
