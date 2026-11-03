require "hive/dependencies"

module Hive
  module Recovery
    # Presentation of coordinator receipts, without admission or retry policy.
    # Input completeness is supplied by the coding brainstorm parser at the
    # status boundary; other workflows keep their existing input contract.
    module Presentation
      View = Data.define(:kind, :label, :detail)
      HOLD_DECISIONS = %w[
        global_cap project_cap daily_cap provider_hold blocked_on_dependency
        wait_for_debounce project_disabled shutdown attempt_capacity cooldown
      ].freeze

      module_function

      def value(row, key)
        return row.public_send(key) if row.respond_to?(key)
        return row[key] if row.respond_to?(:key?) && row.key?(key)
        return row[key.to_s] if row.respond_to?(:[])

        nil
      end

      def missing_input?(row)
        action = value(row, :action) || value(row, :action_key)
        return false unless action.to_s == "needs_input"
        return true if value(row, :unanswered_questions).to_i.positive? || value(row, :answers_complete) == false
        return false if value(row, :answers_complete) == true
        recovery = value(row, :recovery)
        return false if recovery.is_a?(Hash) && recovery["variant"] == "failed_edit"

        true
      end

      def for_row(row)
        recovery = value(row, :recovery)
        recovery = nil unless recovery.is_a?(Hash) && recovery["status"] != "terminal"
        complete_waiting = (value(row, :action) || value(row, :action_key)).to_s == "needs_input" &&
          value(row, :answers_complete) == true
        scheduler_status = value(row, :scheduler_status) || recovery&.fetch("scheduler_status", nil)
        return nil unless recovery || complete_waiting || !value(row, :answers_complete).nil?

        if (recovery || !missing_input?(row)) &&
           (%w[stale unavailable invalid].include?(scheduler_status) || recovery&.fetch("status", nil) == "unavailable")
          return View.new(kind: "unavailable", label: "Status unavailable",
            detail: recovery ? "Scheduler observation unavailable; stored recovery #{recovery['status']}: #{failure_detail(recovery)}" :
              "Scheduler observation unavailable; refresh status before choosing an action.")
        end
        if recovery && recovery["status"] == "blocked"
          label = recovery["escalation_tier"] == "parked" || %w[operator hive].include?(recovery["owner"]) ?
            "Needs execution repair" : "Needs recovery"
          return View.new(kind: "repair", label: label, detail: failure_detail(recovery))
        end
        blockers = Hive::Dependencies.blocker_names(
          unmet_dependencies: value(row, :unmet_dependencies), blocked_by: value(row, :blocked_by))
        if value(row, :blocked) == true || blockers.any?
          return hold_view(row, recovery, blockers)
        end
        if missing_input?(row)
          count = value(row, :unanswered_questions).to_i
          detail = count.positive? ? "#{count} questions need an answer." : "Input is required for this step."
          detail += " Recovery: #{failure_detail(recovery)}" if recovery
          label = value(row, :answers_complete).nil? ? (value(row, :action_label) || "Needs your input") : "Answer questions"
          return View.new(kind: "input", label: label, detail: detail)
        end
        if recovery && recovery["status"] == "running"
          return View.new(kind: "running", label: "Agent running", detail: "Recovery attempt is running; #{failure_detail(recovery)}")
        end
        if value(row, :held) || recovery&.fetch("scheduler_hold", nil)
          return hold_view(row, recovery, blockers)
        end
        if recovery && %w[cooldown queued].include?(recovery["status"])
          time = recovery["next_eligible_at"]
          detail = time.to_s.empty? ? "retry time unavailable" : "retry at #{time}"
          detail = "queued #{detail}" if recovery["status"] == "queued"
          return View.new(kind: recovery["status"], label: "Needs recovery",
            detail: "#{detail}; #{failure_detail(recovery)}")
        end
        View.new(kind: "waiting", label: "Waiting", detail: "Answers complete; awaiting scheduler disposition.")
      end

      def failure_detail(recovery)
        [ recovery["reason"] || recovery["failure_origin"], recovery["owner"], recovery["remediation"] ]
          .compact.reject { |part| part.to_s.empty? }.join("; ")
      end

      def hold_view(row, recovery, blockers)
        held = value(row, :held)
        held_reason = if held.is_a?(Hash)
          [ held["reason"], held["provider"] ].compact.join("; ")
        else
          held.to_s
        end
        detail = if recovery && recovery["scheduler_hold"]
          recovery["scheduler_hold"]
        elsif blockers.any?
          "Waiting for #{blockers.join(', ')}."
        elsif !held_reason.empty?
          "Waiting for #{held_reason}."
        else
          "Waiting for the current scheduler hold."
        end
        detail += " Recovery: #{failure_detail(recovery)}" if recovery
        View.new(kind: "hold", label: recovery ? "Needs recovery" : "Waiting", detail: detail)
      end
    end
  end
end
