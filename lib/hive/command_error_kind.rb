# frozen_string_literal: true

module Hive
  module CommandErrorKind
    ALL = %w[
      command_conflict command_in_progress command_unresolved_pending
      command_pin_horizon_elapsed command_capacity_exhausted command_nonterminal_limit
      command_concurrency_limit command_prune_busy command_prune_storage_unavailable
      command_prune_preview_unavailable command_orphaned_pin
      command_original_result_unavailable command_intake_disabled
      task_capability_invalid_selection task_capability_policy_conflict
      task_capability_missing_skill task_capability_verification_unavailable
      task_capability_approval_required task_capability_approval_scope
      task_capability_blocked task_capability_stale_preview
      task_capability_operator_required task_capability_route_unavailable
    ].freeze

    module_function

    def typed(error)
      return error.reason if defined?(Hive::TaskCapabilities::Admission::Error) && error.is_a?(Hive::TaskCapabilities::Admission::Error)
      return error.reason if error.is_a?(Hive::CommandOutcomeError)
      return error.reason if error.is_a?(Hive::CommandCapacityError)
      return error.reason if error.is_a?(Hive::CommandIntakeDisabled)

      nil
    end
  end
end
