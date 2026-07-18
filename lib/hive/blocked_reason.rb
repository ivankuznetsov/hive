module Hive
  class BlockedReason
    STATE_RANK = {
      "needs-you" => 0,
      "error" => 1,
      "recovery" => 2,
      "running" => 3,
      "blocked" => 4,
      "ready" => 5,
      "idle" => 6
    }.freeze

    def self.dominant_state(needs_input: false, error: false, recovery: false,
                            running: false, queued: false, blocked: false, ready: false)
      return "needs-you" if needs_input
      return "error" if error
      return "recovery" if recovery
      return "running" if running || queued
      return "blocked" if blocked
      return "ready" if ready

      "idle"
    end

    def self.for(**kwargs) = new(**kwargs)

    def initialize(action_key:, blocked_by: nil, dependency_stage: nil,
                   admission_error: nil, diagnostic: nil, live_task_lock: false,
                   queued_request: nil)
      @action_key = action_key.to_s
      @blocked_by = blocked_by
      @dependency_stage = dependency_stage
      @admission_error = admission_error
      @diagnostic = diagnostic
      @live_task_lock = live_task_lock
      @queued_request = queued_request
    end

    def payload
      return admission_payload if @admission_error
      return dependency_payload if @blocked_by
      return diagnostic_payload if @diagnostic
      return running_payload if @live_task_lock || @queued_request

      nil
    end

    private

    def admission_payload
      error = @admission_error.respond_to?(:to_h) ? @admission_error.to_h : @admission_error
      {
        "summary" => "Dependency admission needs configuration",
        "detail" => error["safe_correction"].to_s,
        "remedies" => [ { "kind" => "manual", "text" => error["safe_correction"].to_s } ]
      }
    end

    def dependency_payload
      {
        "summary" => "Dependency has not reached its admission gate",
        "detail" => "#{@blocked_by} is currently at #{@dependency_stage}.",
        "remedies" => [ { "kind" => "open_task", "task" => @blocked_by.to_s } ]
      }
    end

    def diagnostic_payload
      {
        "summary" => @diagnostic["summary"].to_s,
        "detail" => @diagnostic["detail"].to_s,
        "remedies" => diagnostic_remedies
      }
    end

    def diagnostic_remedies
      action = @diagnostic["suggested_next_action"]
      return [ { "kind" => "manual", "text" => "Inspect the task details and repair the recorded state." } ] unless action

      [ { "kind" => action["kind"].to_s, "command" => action["command"] } ]
    end

    def running_payload
      {
        "summary" => @queued_request ? "Transition is queued" : "Task is running",
        "detail" => "Wait for the authoritative task snapshot to change.",
        "remedies" => []
      }
    end
  end
end
