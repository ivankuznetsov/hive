require "time"
require "hive/operational_action"
require "hive/workflows"

module Hive
  # Agent-first projection over the established hive-status graph. The input
  # is deliberately the public v6 payload so the compatibility serializer
  # remains untouched and every operational consumer shares one collected
  # graph instead of re-scanning task folders independently.
  class OperationalStatus
    STATES = %w[
      unknown running needs_repair waiting_on_you
      waiting_on_provider_or_scheduler completion_ready idle
    ].freeze
    STATE_PRECEDENCE = %w[
      running needs_repair waiting_on_you waiting_on_provider_or_scheduler
      completion_ready unknown idle
    ].freeze
    RUNNING_ACTIONS = %w[agent_running].freeze
    REPAIR_ACTIONS = %w[error recover_execute recover_review admission_error].freeze
    COMPLETION_ACTIONS = %w[ready_to_archive review_parked].freeze
    HUMAN_ACTIONS = %w[needs_input].freeze
    CODING_PLAN_STAGE = Hive::Workflows::Registry.default.stage_named("plan").dir.freeze

    def initialize(status_payload:, project_context: {}, scheduler_snapshot: nil, now: Time.now.utc)
      @status_payload = status_payload
      @project_context = project_context
      @scheduler_snapshot = scheduler_snapshot
      @now = now.utc
    end

    def to_h
      validate_source!
      projects = @status_payload.fetch("projects")
      archived = archive_rows(projects)
      active = active_rows(projects)
      issues = source_issues(projects, active)
      task_source_status = task_source_status(projects, active)
      @scheduler_join_issues = []
      @scheduler_join_issue_keys = {}
      scheduler = scheduler_payload(projects)
      issues.concat(scheduler.fetch("issues"))
      tasks = active.map { |project, row| project_row(project, row, scheduler) }
      issues.concat(@scheduler_join_issues)
      completeness = combined_completeness(
        task_source_status,
        scheduler.fetch("status"),
        scheduler_join_complete: @scheduler_join_issues.empty?
      )
      counts = STATES.to_h { |state| [ state, tasks.count { |row| row.fetch("state") == state } ] }

      {
        "schema" => "hive-operational-status",
        "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-operational-status"),
        "ok" => true,
        "generated_at" => @now.iso8601,
        "completeness" => completeness,
        "source" => {
          "task_graph" => {
            "schema" => @status_payload.fetch("schema"),
            "schema_version" => @status_payload.fetch("schema_version"),
            "generated_at" => @status_payload.fetch("generated_at"),
            "status" => task_source_status,
            "projects_total" => projects.size,
            "projects_healthy" => projects.count { |project| project["error"].nil? }
          },
          "scheduler" => {
            "status" => scheduler.fetch("status"),
            "observed_at" => scheduler["observed_at"]
          }
        },
        "summary" => {
          "overall_state" => overall_state(tasks, completeness),
          "active" => tasks.size,
          "archived" => archived.size,
          "projects_total" => projects.size,
          "projects_healthy" => projects.count { |project| project["error"].nil? },
          "states" => counts
        },
        "daemon" => daemon_payload(projects, scheduler),
        "scheduler" => scheduler.reject { |key, _| key == "issues" },
        "archive" => archive_payload(archived),
        "issues" => issues,
        "tasks" => tasks
      }
    end

    private

    def validate_source!
      return if @status_payload["ok"] == true && @status_payload["schema"] == "hive-status"

      raise ArgumentError, "operational status requires a successful hive-status payload"
    end

    def archive_rows(projects)
      projects.flat_map do |project|
        Array(project["tasks"]).filter_map do |row|
          [ project, row ] if row["action"] == "archived"
        end
      end
    end

    def active_rows(projects)
      projects.flat_map do |project|
        Array(project["tasks"]).filter_map do |row|
          [ project, row ] unless row["action"] == "archived"
        end
      end
    end

    def source_issues(projects, active)
      issues = projects.filter_map do |project|
        next unless project["error"]

        issue(
          code: project.fetch("error"), source: "task_graph", project: project["name"],
          message: "project status is unavailable: #{project.fetch('error')}",
          remediation: "run hive doctor and inspect the registered project path"
        )
      end
      projects.each do |project|
        legacy = Array(project["legacy_stage_dirs"])
        next if legacy.empty?

        total = legacy.sum { |entry| entry.fetch("task_count") }
        dirs = legacy.map do |entry|
          "#{entry.fetch('stage_dir')} (#{entry.fetch('task_count')})"
        end.join(", ")
        issues << issue(
          code: "legacy_stage_dirs", source: "task_graph", project: project["name"],
          message: "#{total} task#{total == 1 ? '' : 's'} hidden in legacy stage dirs: #{dirs}",
          remediation: project["legacy_migrate_command"] || "hive migrate"
        )
      end
      active.each do |project, row|
        next unless invalid_task?(row)

        issues << issue(
          code: "invalid_task", source: "task_graph", project: project["name"], task: row["slug"],
          message: row.dig("attrs", "message") || "task metadata is invalid",
          remediation: "repair the task workflow metadata, then re-run hive status"
        )
      end
      issues
    end

    def issue(code:, source:, message:, remediation:, project: nil, task: nil, severity: "warning")
      {
        "code" => code,
        "severity" => severity,
        "source" => source,
        "project" => project,
        "task" => task,
        "message" => message.to_s,
        "remediation" => remediation.to_s
      }
    end

    def task_source_status(projects, active)
      return "complete" if projects.empty?

      failed = projects.count { |project| project["error"] }
      incomplete = failed.positive? || projects.any? { |project| Array(project["legacy_stage_dirs"]).any? } ||
                   active.any? { |_, row| invalid_task?(row) }
      return "complete" unless incomplete
      return "unknown" if failed == projects.size

      "partial"
    end

    def scheduler_payload(projects)
      enabled = projects.filter_map do |project|
        project["name"] if daemon_enabled?(project["name"])
      end
      if enabled.empty?
        return {
          "status" => "not_applicable", "reason" => "no project is daemon-enabled",
          "observed_at" => nil, "valid_until" => nil, "tick_sequence" => nil,
          "capacity" => nil, "queue" => nil, "provider_holds" => [], "issues" => []
        }
      end

      # U2 replaces this unavailable branch with the validated atomic daemon
      # record. Keeping the shape now pins the task-only degradation contract.
      return scheduler_from_snapshot(@scheduler_snapshot) if @scheduler_snapshot

      {
        "status" => "unavailable",
        "reason" => "daemon observation is unavailable for #{enabled.join(', ')}",
        "observed_at" => nil,
        "valid_until" => nil,
        "tick_sequence" => nil,
        "capacity" => nil,
        "queue" => nil,
        "provider_holds" => [],
        "issues" => [ issue(
          code: "scheduler_unavailable", source: "scheduler",
          message: "daemon-enabled work has no current scheduler observation",
          remediation: "run hive daemon status --json and wait for one complete reconciliation tick"
        ) ]
      }
    end

    def scheduler_from_snapshot(snapshot)
      @daemon_snapshot = snapshot
      status = snapshot.fetch("status", "unavailable")
      @scheduler_task_index = if status == "current"
        Array(snapshot["tasks"]).to_h do |task|
          [ [ task.dig("identity", "project"), task.dig("identity", "slug") ], task ]
        end
      else
        {}
      end
      issues = []
      unless status == "current"
        issues << issue(
          code: "scheduler_#{status}", source: "scheduler",
          message: "daemon scheduler observation is #{status}: #{snapshot['reason'] || 'unknown reason'}",
          remediation: "check hive daemon status --json and wait for one complete reconciliation tick"
        )
      end
      {
        "status" => status,
        "reason" => snapshot["reason"],
        "observed_at" => snapshot["observed_at"],
        "valid_until" => snapshot["valid_until"],
        "tick_sequence" => snapshot["tick_sequence"],
        "capacity" => snapshot["capacity"],
        "queue" => snapshot["queue"],
        "provider_holds" => Array(snapshot["provider_holds"]),
        "issues" => issues + Array(snapshot["issues"])
      }
    end

    def daemon_payload(projects, scheduler)
      status = if projects.none? { |project| daemon_enabled?(project["name"]) }
        "not_applicable"
      elsif scheduler.fetch("status") == "current"
        "healthy"
      else
        "unknown"
      end
      daemon = @daemon_snapshot.is_a?(Hash) ? @daemon_snapshot["daemon"] : nil
      {
        "status" => status,
        "generation" => daemon&.fetch("generation", nil),
        "pid" => daemon&.fetch("pid", nil),
        "process_start_time" => daemon&.fetch("process_start_time", nil),
        "phase" => @daemon_snapshot&.fetch("phase", nil),
        "observed_at" => scheduler["observed_at"]
      }
    end

    def daemon_enabled?(project_name)
      @project_context.dig(project_name, "daemon_enabled") == true ||
        @project_context.dig(project_name, :daemon_enabled) == true
    end

    def combined_completeness(task_status, scheduler_status, scheduler_join_complete: true)
      return "unknown" if task_status == "unknown"
      return "partial" if task_status == "partial" || !scheduler_join_complete
      return "partial" unless %w[current not_applicable].include?(scheduler_status)

      "complete"
    end

    def project_row(project, row, scheduler)
      reasons = reasons_for(project, row)
      state, owner = classify(project, row)
      scheduler_disposition, scheduler_freshness = scheduler_disposition_for(
        project, row, scheduler
      )
      if scheduler_disposition
        scheduler_reason = reason(
          scheduler_disposition.fetch("decision", "scheduler_decision"),
          scheduler_disposition.fetch("reason", "scheduler disposition is unavailable"),
          "scheduler"
        )
        reasons.unshift(scheduler_reason) if material_scheduler_disposition?(scheduler_disposition)
        scheduler_state, scheduler_owner = classify_scheduler_disposition(scheduler_disposition)
        unless running?(row) || scheduler_state.nil?
          state = scheduler_state
          owner = scheduler_owner
        end
      end
      action = Hive::OperationalAction.descriptor(project: project.fetch("name"), row: row)
      action = nil if daemon_enabled?(project.fetch("name"))
      {
        "identity" => {
          "project" => project.fetch("name"),
          "slug" => row.fetch("slug"),
          "id" => row["id"],
          "display_name" => row["display_name"],
          "folder" => row.fetch("folder")
        },
        "workflow" => row["workflow"],
        "position" => {
          "stage" => row.fetch("stage"),
          "marker" => row.fetch("marker"),
          "allowed_outcomes" => Array(row["outcomes"])
        },
        "liveness" => {
          "status" => liveness_status(row),
          "pid" => row["task_lock_pid"] || row["claude_pid"],
          "attempt_id" => row["attempt_id"],
          "task_generation" => row["task_generation"]
        },
        "state" => state,
        "blocker_owner" => owner,
        "reason" => reasons.first.fetch("message"),
        "reasons" => reasons,
        "provider" => provider_payload(row),
        "retry" => retry_payload(scheduler_disposition),
        "dependency" => {
          "blocked" => row["blocked"] == true,
          "blocked_by" => row["blocked_by"],
          "dependency_stage" => row["dependency_stage"],
          "admission_error" => row["admission_error"]
        },
        "freshness" => {
          "task_observed_at" => @status_payload.fetch("generated_at"),
          "scheduler_status" => scheduler_freshness
        },
        "evidence" => {
          "task_action" => row["action"],
          "task_action_label" => row["action_label"],
          "marker_attrs" => row["attrs"] || {},
          "diagnostic" => row["diagnostic"],
          "condition_warning" => row["condition_warning"],
          "held" => row["held"]
        },
        "action" => action
      }
    end

    def scheduler_disposition_for(project, row, scheduler)
      return [ nil, "not_applicable" ] unless daemon_enabled?(project.fetch("name"))

      status = scheduler.fetch("status")
      return [ nil, status ] unless status == "current"

      key = [ project.fetch("name"), row.fetch("slug") ]
      observed = (@scheduler_task_index || {})[key]
      unless observed
        add_scheduler_join_issue(
          code: "scheduler_task_missing", project: key[0], task: key[1],
          message: "current task is absent from the daemon's completed observation"
        )
        return [ nil, "unavailable" ]
      end
      unless scheduler_task_matches?(observed, row)
        add_scheduler_join_issue(
          code: "scheduler_task_mismatch", project: key[0], task: key[1],
          message: "task identity, policy, or generation changed after the daemon observation"
        )
        return [ nil, "unavailable" ]
      end

      disposition = observed["disposition"]
      unless disposition.is_a?(Hash) && disposition["status"] == "available"
        add_scheduler_join_issue(
          code: "scheduler_task_changed", project: key[0], task: key[1],
          message: "task changed during the daemon tick; no disposition is authoritative yet"
        )
        return [ nil, "unavailable" ]
      end

      [ disposition, "current" ]
    end

    def scheduler_task_matches?(observed, row)
      expected = {
        "folder" => row["folder"],
        "workflow" => row["workflow"],
        "stage" => row["stage"],
        "marker" => row["marker"],
        "marker_attrs" => row["attrs"] || {},
        "task_generation" => row["task_generation"],
        "condition_task_generation" => row["condition_task_generation"],
        "commit_generation" => row["commit_generation"],
        "attempt_id" => row["attempt_id"],
        "state_file_mtime" => row["mtime"],
        "action" => row["action"],
        "depends_on" => row["depends_on"],
        "blocked_by" => row["blocked_by"],
        "dependency_stage" => row["dependency_stage"],
        "blocked" => row["blocked"] == true,
        "admission_error" => row["admission_error"]
      }
      actual = {
        "folder" => observed.dig("identity", "folder"),
        "workflow" => observed["workflow"],
        "stage" => observed["stage"],
        "marker" => observed["marker"],
        "marker_attrs" => observed["marker_attrs"],
        "task_generation" => observed["task_generation"],
        "condition_task_generation" => observed["condition_task_generation"],
        "commit_generation" => observed["commit_generation"],
        "attempt_id" => observed["attempt_id"],
        "state_file_mtime" => observed["state_file_mtime"],
        "action" => observed["action"],
        "depends_on" => observed["depends_on"],
        "blocked_by" => observed["blocked_by"],
        "dependency_stage" => observed["dependency_stage"],
        "blocked" => observed["blocked"],
        "admission_error" => observed["admission_error"]
      }
      expected.all? do |key, value|
        other = actual[key]
        scheduler_value_matches?(value, other)
      end
    end

    def scheduler_value_matches?(expected, actual)
      return actual.nil? if expected.nil?
      return expected == actual if expected == true || expected == false
      return canonical_scheduler_value(expected) == canonical_scheduler_value(actual) if
        expected.is_a?(Hash) || expected.is_a?(Array)

      expected.to_s == actual.to_s
    end

    def canonical_scheduler_value(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.to_h do |key|
          original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          [ key, canonical_scheduler_value(value.fetch(original)) ]
        end
      when Array
        value.map { |entry| canonical_scheduler_value(entry) }
      else
        value
      end
    end

    def add_scheduler_join_issue(code:, project:, task:, message:)
      key = [ code, project, task ]
      return if (@scheduler_join_issue_keys ||= {}).key?(key)

      @scheduler_join_issue_keys[key] = true
      @scheduler_join_issues << issue(
        code: code,
        source: "scheduler",
        project: project,
        task: task,
        message: message,
        remediation: "request a fresh operational status after the next daemon tick"
      )
    end

    def material_scheduler_disposition?(disposition)
      !%w[not_evaluated skip project_disabled].include?(disposition["decision"])
    end

    def classify_scheduler_disposition(disposition)
      decision = disposition["decision"]
      case decision
      when "provider_hold"
        [ "waiting_on_provider_or_scheduler", "provider" ]
      when "global_cap", "project_cap", "daily_cap", "cooldown", "in_flight",
           "dispatched", "wait_for_debounce", "record_baseline", "poll_for_merge",
           "merge_watch", "blocked_on_dependency", "retry_cooldown", "retry_pending"
        [ "waiting_on_provider_or_scheduler", "scheduler" ]
      when "retry_in_flight"
        [ "running", "agent" ]
      when "retry_safety_blocked"
        [ "needs_repair", disposition["owner"] || "operator" ]
      when "wait_for_answers"
        [ "waiting_on_you", "operator" ]
      when "quarantined", "project_dropped", "folder_missing", "folder_missing_nil",
           "plan_approval_invalid", "legacy_layout", "markerless_stalled", "recovery_exhausted"
        [ "needs_repair", disposition["owner"] || "operator" ]
      else
        [ nil, nil ]
      end
    end

    def classify(project, row)
      return [ "unknown", "unknown" ] if invalid_task?(row)
      return [ "needs_repair", "hive" ] if stale_liveness?(row)
      return [ "running", "agent" ] if running?(row)
      return [ "waiting_on_provider_or_scheduler", "scheduler" ] if automatic_error_retry?(project, row)
      return [ "needs_repair", "operator" ] if repair?(row)
      return [ "waiting_on_provider_or_scheduler", "provider" ] if row["held"]
      if human_input?(row)
        return [ "waiting_on_provider_or_scheduler", "scheduler" ] if daemon_plan_approval?(project, row)

        return [ "waiting_on_you", "operator" ]
      end
      return [ "waiting_on_provider_or_scheduler", "scheduler" ] if row["blocked"] == true
      return [ "completion_ready", daemon_enabled?(project["name"]) ? "scheduler" : "operator" ] if
        COMPLETION_ACTIONS.include?(row["action"])

      [ "idle", daemon_enabled?(project["name"]) ? "scheduler" : "none" ]
    end

    def retry_payload(disposition)
      return nil unless disposition.is_a?(Hash)
      return nil unless disposition["decision"].to_s.start_with?("retry_")

      {
        "due" => disposition["retry_due"] == true,
        "retry_at" => disposition["retry_at"],
        "safe" => disposition["retry_safe"] == true,
        "safety_reason" => disposition["safety_reason"]
      }
    end

    def invalid_task?(row)
      row["action"] == "error" && row.dig("attrs", "reason") == "invalid_task"
    end

    def running?(row)
      return true if row["live_task_lock"] == true || row["claude_pid_alive"] == true
      return false if stale_liveness?(row)

      RUNNING_ACTIONS.include?(row["action"])
    end

    def stale_liveness?(row)
      (row["claude_pid"] && row["claude_pid_alive"] == false) ||
        (row["task_lock_pid"] && row["live_task_lock"] == false)
    end

    def repair?(row)
      REPAIR_ACTIONS.include?(row["action"]) || row["admission_error"] || row["condition_warning"]
    end

    def human_input?(row)
      HUMAN_ACTIONS.include?(row["action"])
    end

    def daemon_plan_approval?(project, row)
      daemon_enabled?(project["name"]) && row["workflow"] == "coding" && row["stage"] == CODING_PLAN_STAGE
    end

    def automatic_error_retry?(project, row)
      daemon_enabled?(project["name"]) &&
        auto_retry_enabled?(project["name"]) &&
        %w[error review_error].include?(row["marker"].to_s)
    end

    def auto_retry_enabled?(project_name)
      @project_context.dig(project_name, "auto_retry_enabled") == true ||
        @project_context.dig(project_name, :auto_retry_enabled) == true
    end

    def reasons_for(project, row)
      reasons = []
      if invalid_task?(row)
        reasons << reason("invalid_task", row.dig("attrs", "message") || "task metadata is invalid", "task")
      elsif stale_liveness?(row)
        message = row.dig("diagnostic", "summary") || row.dig("attrs", "message") ||
                  "recorded task runner is no longer alive"
        reasons << reason("stale_runner", message, "liveness")
      elsif running?(row)
        message = if row["task_lock_pid"]
          "task runner holds the live lock (pid #{row.fetch('task_lock_pid')})"
        elsif row["claude_pid"]
          "agent process #{row.fetch('claude_pid')} is alive"
        else
          "task has a verified live runner"
        end
        reasons << reason("live_runner", message, "liveness")
      elsif row["admission_error"]
        error = row.fetch("admission_error")
        reasons << reason(error.fetch("reason_code"), error.fetch("safe_correction"), "dependency")
      elsif automatic_error_retry?(project, row)
        marker = row["marker"].to_s.upcase
        reasons << reason(
          "error_retry_scheduled",
          "#{marker} remains scheduled for a guarded retry after the shared cooldown",
          "scheduler"
        )
      elsif repair?(row)
        message = row.dig("diagnostic", "summary") || row.dig("attrs", "message") ||
                  row.dig("attrs", "reason") || row["action_label"] || "task needs repair"
        reasons << reason("task_repair", message, "task")
      elsif row["held"]
        held = row.fetch("held")
        provider = held["provider"] || "provider"
        retry_text = held["retry_after"] ? " until #{held.fetch('retry_after')}" : ""
        reasons << reason("provider_quota", "#{provider} quota hold#{retry_text}", "provider")
      elsif daemon_plan_approval?(project, row)
        reasons << reason("daemon_plan_approval", "daemon owns plan approval for this enrolled project", "scheduler")
      elsif human_input?(row)
        unanswered = row["unanswered_questions"].to_i
        message = unanswered.positive? ? "#{unanswered} unanswered questions" : row["action_label"]
        reasons << reason("human_input", message || "task requires an operator decision", "task")
      elsif row["blocked"] == true
        message = row["blocked_by"] ? "blocked by #{row.fetch('blocked_by')}" : "blocked by a task dependency"
        reasons << reason("dependency_wait", message, "dependency")
      elsif COMPLETION_ACTIONS.include?(row["action"])
        reasons << reason("completion_ready", row["action_label"] || "task is ready to complete", "task")
      else
        reasons << reason("ready_for_dispatch", row["action_label"] || "task is ready for its next workflow step", "task")
      end

      if row["held"] && reasons.none? { |entry| entry["code"] == "provider_quota" }
        held = row.fetch("held")
        reasons << reason("provider_quota", "#{held['provider'] || 'provider'} quota hold", "provider")
      end
      if row["blocked_by"] && reasons.none? { |entry| entry["code"] == "dependency_wait" }
        reasons << reason("dependency_wait", "blocked by #{row.fetch('blocked_by')}", "dependency")
      end
      if row["condition_warning"]
        reasons << reason("condition_warning", row.fetch("condition_warning"), "condition")
      end
      reasons
    end

    def reason(code, message, source)
      { "code" => code, "message" => message.to_s, "source" => source, "freshness" => "current" }
    end

    def provider_payload(row)
      return nil unless row["held"]

      { "name" => row.dig("held", "provider"), "retry_after" => row.dig("held", "retry_after") }
    end

    def liveness_status(row)
      return "running" if running?(row)
      return "stale" if stale_liveness?(row)

      "not_running"
    end

    def archive_payload(archived)
      grouped = archived.group_by { |project, _| project.fetch("name") }
      {
        "count" => archived.size,
        "by_project" => grouped.keys.sort.map do |project|
          { "project" => project, "count" => grouped.fetch(project).size }
        end
      }
    end

    def overall_state(tasks, completeness)
      return "idle" if tasks.empty? && completeness == "complete"

      STATE_PRECEDENCE.each do |state|
        next if state == "idle" && completeness != "complete"
        return state if tasks.any? { |row| row.fetch("state") == state }
      end
      completeness == "complete" ? "idle" : "unknown"
    end
  end
end
