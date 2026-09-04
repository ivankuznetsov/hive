# Presentation only: Hive still owns classification, evidence and action guards.
# A ready next action is not proof that an agent has started or a task has finished.
class TaskDisplay
  STATES = {
    "running" => "Running", "attention" => "Needs you", "ready" => "Ready",
    "waiting" => "Waiting", "unknown" => "Unavailable", "paused" => "Paused", "completed" => "Completed"
  }.freeze

  attr_reader :task

  def initialize(task, fresh: true, archived: false)
    @task, @fresh, @archived = task, fresh, archived
  end

  def state = status.first
  def label = status.last

  def detail
    return nil if state == "completed"
    return "Live status could not be confirmed. Actions are paused until it refreshes." unless @fresh
    if task["action"] == "admission_error"
      return task.dig("admission_error", "safe_correction").presence || "Repair the task dependency before it can continue."
    end
    return "Waiting for #{task['blocked_by']}." if task["blocked_by"].present?

    recovery = task.recovery || {}
    reason = recovery["remediation"].presence || task.dig("diagnostic", "summary").presence
    return reason if reason
    return "#{task['unanswered_questions']} questions need an answer." if task["unanswered_questions"].to_i.positive?
    return "An agent is working on this step." if state == "running"
    return "This step is finished; the task has not been archived yet." if task["action"] == "ready_to_archive"

    task["action_label"].presence unless task["action_label"].to_s.casecmp?(label)
  end

  private

  def status
    @status ||= begin
      action = task["action"].to_s
      if @archived || task.terminal? || action == "archived"
        reason = task.dig("closure", "reason")
        [ "completed", reason.present? ? reason.humanize : (@archived ? "Archived" : "Completed") ]
      elsif !@fresh
        [ "unknown", "Status unavailable" ]
      elsif task["action_label"] == Hive::TaskAction::ACTIONS.fetch(:patrol_fix_rejected).fetch(:label)
        [ "paused", "Rejected" ]
      elsif task["action_label"] == Hive::TaskAction::ACTIONS.fetch(:patrol_fix_blocked).fetch(:label)
        [ "attention", "Blocked" ]
      elsif task["action_label"] == Hive::TaskAction::ACTIONS.fetch(:patrol_fix_escalated).fetch(:label)
        [ "attention", "Needs attention" ]
      elsif action == "admission_error"
        [ "attention", "Needs attention" ]
      elsif task["blocked"] || task["blocked_by"].present?
        [ "waiting", "Waiting on a task" ]
      elsif task["held"].present?
        [ "waiting", "Waiting for capacity" ]
      elsif task.recovery && %w[queued cooldown running blocked unavailable].include?(task.recovery["status"])
        {
          "queued" => [ "waiting", "Retry queued" ],
          "cooldown" => [ "waiting", "Waiting to retry" ],
          "running" => [ "running", "Running" ],
          "blocked" => [ "attention", "Retry blocked" ],
          "unavailable" => [ "unknown", "Status unavailable" ]
        }.fetch(task.recovery["status"])
      elsif action == "agent_running"
        [ "running", "Running" ]
      elsif %w[needs_input plan_review_decision plan_review_degraded].include?(action)
        [ "attention", "Needs your input" ]
      elsif %w[plan_review_blocked patrol_fix_blocked].include?(action)
        [ "attention", "Blocked" ]
      elsif %w[error recover_execute recover_review recover_draft_pr plan_review_unsupported outcome_evidence_rework patrol_fix_escalated].include?(action)
        [ "attention", "Needs attention" ]
      elsif action == "plan_review_retry"
        [ "waiting", "Waiting to retry" ]
      elsif action == "plan_reviewing"
        [ "waiting", "Plan review in progress" ]
      elsif %w[manual_steering patrol_fix_rejected review_parked].include?(action)
        [ "paused", "Paused" ]
      elsif action == "ready_to_archive"
        [ "ready", "Ready to archive" ]
      elsif action.start_with?("ready_")
        [ "ready", task.passable? ? "Ready to continue" : "Ready" ]
      else
        [ "unknown", "Status unavailable" ]
      end
    end
  end
end
