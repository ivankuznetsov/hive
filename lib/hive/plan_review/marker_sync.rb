require "hive/markers"

module Hive
  module PlanReview
    # The planner can only finish authoring the document; required critique is
    # part of plan completion. Keep the plan marker non-terminal until the
    # review projection grants execution, then let PlanApproval perform the
    # guarded WAITING -> COMPLETE transition immediately before develop.
    module MarkerSync
      module_function

      def hold_until_cleared!(task:, projection:)
        return unless projection && !projection.record.execution_allowed?

        Hive::Markers.set_if_current(
          task.state_file, expected_name: :complete, name: :waiting
        )
      end
    end
  end
end
