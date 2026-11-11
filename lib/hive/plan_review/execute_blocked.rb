module Hive
  module PlanReview
    # Execute entry refused by `TransitionGuard` (for example `plan.md` edited
    # after its review cleared). Replaying execute fails identically until an
    # operator returns the task to plan and restarts its review, or restores
    # the reviewed plan. Execute records the refusal as a typed ERROR with this
    # reason so the daemon never retries it as a markerless failure, and every
    # status surface can name the remedy (hivedev, 2026-11-10: a backward move
    # into execute after an operator plan edit retried the same refusal on
    # every cooldown while status called it "automatic retry is eligible").
    #
    # Dependency-free on purpose: `Hive::Recovery` (loaded by `Hive::Markers`)
    # reads this vocabulary, so it must not pull in the plan-review runtime.
    module ExecuteBlocked
      REASON = "plan_review_blocked".freeze
      PLAN_STAGE = "3-plan".freeze # coding-scoped: plan review only gates the coding plan stage
      PLAN_CHANGED = "canonical plan changed".freeze
      FALLBACK_REMEDIATION = "plan review blocks execution; move the task back to " \
                             "#{PLAN_STAGE} and restart its plan review " \
                             "(`hive plan-review TASK restart` or `hive plan-review-run TASK`), " \
                             "or restore the reviewed plan.md and retry".freeze

      module_function

      def marker?(attrs)
        return false unless attrs.respond_to?(:[])

        (attrs["reason"] || attrs[:reason]).to_s == REASON
      end

      # ERROR marker attrs for a refused execute entry. `required_action` is
      # the guard's own wording; `message` is the operator remedy, which
      # recovery receipts, scheduler dispositions, and status reasons reuse.
      def marker_attrs(error, slug:, from_stage:)
        blocker = blocked_reason(error)
        {
          reason: REASON,
          blocker: blocker,
          required_action: error.required_action,
          review_id: error.review_id,
          review_state: error.review_state,
          message: message(slug:, from_stage:, blocked_reason: blocker)
        }
      end

      def message(slug:, from_stage:, blocked_reason: nil)
        cause = blocked_reason.to_s.empty? ? "" : " (#{blocked_reason})"
        "plan review blocks execution#{cause}; Hive will not retry this automatically. " \
          "#{remedy(slug:, from_stage:, blocked_reason:)}"
      end

      # Concrete next steps. `plan-review-run` only accepts a task at plan, so
      # the backward move comes first; restoring the reviewed bytes is offered
      # only when the plan itself is what changed.
      def remedy(slug:, from_stage:, blocked_reason: nil)
        steps = "Move the task back to #{PLAN_STAGE} " \
                "(`hive approve #{slug} --to #{PLAN_STAGE} --from #{from_stage}`), then restart its " \
                "plan review (`hive plan-review #{slug} restart` with the identities from " \
                "`hive plan-review #{slug} show --json`, or `hive plan-review-run #{slug}`)"
        return "#{steps}." unless blocked_reason.to_s.include?(PLAN_CHANGED)

        "#{steps}; or restore the reviewed plan.md and retry."
      end

      # Remediation for a recorded marker (recovery receipts, dispatcher
      # disposition, operational status, `hive task`).
      def remediation(attrs = {})
        message = attrs.respond_to?(:[]) ? (attrs["message"] || attrs[:message]).to_s : ""
        message.strip.empty? ? FALLBACK_REMEDIATION : message
      end

      # TransitionGuard sets `blocked_reason`; other raisers may only carry
      # the guard's "<reason>; required action: <action>" message shape.
      def blocked_reason(error)
        reason = error.blocked_reason.to_s
        reason.empty? ? error.message.to_s.split("; required action:").first.to_s : reason
      end
    end
  end
end
