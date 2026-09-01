require "hive/patrol_fix/attempt_diagnostic"

module Hive
  module Attempts
    # Consumes one terminal Patrol attempt while both its immutable receipt and
    # live admission metadata are still available. The control plane makes this
    # idempotent when admission refresh and finalization observe the same row.
    class FailureCohortReconciler
      def initialize(store:)
        @store = store
      end

      def reconcile(record:, admission:)
        return false unless eligible?(record, admission)

        date = admission.fetch("utc_date")
        if record.outcome == "succeeded"
          return @store.record_failure_cohort_success(
            attempt_id: record.attempt_id, date: date
          )
        end
        return false unless %w[failed cancelled].include?(record.outcome)

        bound = Hive::PatrolFix::AttemptDiagnostic.read_bound(
          store: @store,
          binding: {
            "attempt_id" => record.attempt_id,
            "stage" => record["intended_stage"],
            "task_generation" => record.task_generation,
            "receipt" => record.receipt
          }
        )
        return false unless bound

        @store.record_failure_cohort(
          attempt_id: record.attempt_id,
          identity: {
            "runtime_digest" => admission.fetch("runtime_digest"),
            "project" => record["project"],
            "workflow" => "patrol_fix",
            "stage" => record["intended_stage"],
            "code" => bound.dig("document", "code")
          },
          occurred_at: record["ended_at"]
        )
        true
      end

      private

      def eligible?(record, admission)
        record.state == "terminal" && admission.is_a?(Hash) &&
          admission["workflow"] == "patrol_fix" &&
          admission["stage"] == record["intended_stage"]
      end
    end
  end
end
