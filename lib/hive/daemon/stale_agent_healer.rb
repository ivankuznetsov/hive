require "hive/markers"

module Hive
  module Daemon
    # Reconciles stale compatibility markers and preserves lost-attempt work.
    # It never clears a terminal marker, computes a retry delay/budget, or
    # dispatches a successor; those transitions belong to RetryCoordinator.
    class StaleAgentHealer
      def initialize(controller:, logger:, grace_sec: 300, attempt_store: nil,
                     lost_outcome_store: nil, lost_outcome_processor: nil,
                     failure_reporter: nil, **_retired_options)
        @controller = controller
        @logger = logger
        @grace_sec = grace_sec
        @attempt_store = attempt_store
        @lost_outcome_store = lost_outcome_store
        @lost_outcome_processor = lost_outcome_processor
        @failure_reporter = failure_reporter
      end

      # LostOutcomeProcessor performs only fenced orphan cleanup and dirty-state
      # capture. The coordinator observes the same lost attempt separately and
      # owns its successor authorization.
      def heal_attempt_losses(attempts, now: Time.now.utc)
        Array(attempts).each do |attempt|
          @lost_outcome_processor&.process(attempt, now: now)
          @failure_reporter&.observe(attempt)
        end
      end

      def heal(rows, now: Time.now, legacy_layout_projects: {})
        Array(rows).each do |row|
          next if legacy_layout_projects.include?(row.project)
          next if row.live_task_lock == true && row.claude_pid_alive != false
          next if @controller.running_task?(project: row.project, slug: row.slug)

          reconcile_row(row, now: now)
        end
      end

      private

      def reconcile_row(row, now:)
        marker = row.marker.to_s
        return unless %w[agent_working review_working].include?(marker)

        reason = if row.claude_pid_alive == false
          marker == "review_working" ? "review_agent_died" : "agent_died"
        elsif row.claude_pid_alive.nil? && stale?(row, now)
          marker == "review_working" ? "review_orphaned" : "agent_orphaned"
        end
        return unless reason

        target = marker == "review_working" ? :review_error : :error
        attrs = { reason: reason }
        attrs[:attempt_id] = row.attempt_id if row.respond_to?(:attempt_id) && row.attempt_id
        attrs[:task_generation] = row.task_generation if row.respond_to?(:task_generation) && row.task_generation
        Hive::Markers.set(row.state_file, target, **attrs)
        report_attempt(row, reason)
        @logger.event(
          :agent_reconciled, project: row.project, slug: row.slug, stage: row.stage,
          reason: reason, route: "coordinator"
        )
      rescue SystemCallError, IOError => e
        @logger.event(
          :agent_reconcile_failed, project: row.project, slug: row.slug,
          stage: row.stage, error: "#{e.class}: #{e.message}"
        )
      end

      def report_attempt(row, reason)
        return unless @failure_reporter && @attempt_store && row.respond_to?(:attempt_id)

        attempt = @attempt_store.fetch(row.attempt_id)
        @failure_reporter.observe(attempt, code: reason) if attempt&.final?
      end

      def stale?(row, now)
        mtime = row.state_file_mtime
        mtime && (now - mtime) >= @grace_sec
      end
    end
  end
end
