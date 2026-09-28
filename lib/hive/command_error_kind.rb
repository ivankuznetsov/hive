# frozen_string_literal: true

module Hive
  module CommandErrorKind
    ALL = %w[
      command_conflict command_in_progress command_unresolved_pending
      command_pin_horizon_elapsed command_capacity_exhausted command_nonterminal_limit
      command_concurrency_limit command_prune_busy command_prune_storage_unavailable
      command_prune_preview_unavailable command_orphaned_pin
      command_original_result_unavailable command_intake_disabled
    ].freeze

    module_function

    def typed(error)
      return error.reason if error.is_a?(Hive::CommandOutcomeError)
      return error.reason if error.is_a?(Hive::CommandCapacityError)
      return error.reason if error.is_a?(Hive::CommandIntakeDisabled)

      nil
    end
  end
end
