module Hive
  # Shared, policy-free vocabulary for durable recovery. Mutation and pacing
  # remain owned by RecoveryCoordinator; adapters use Recovery::API.
  module Recovery
    RECOVERABLE_MARKERS = %w[
      error review_error review_stale review_ci_stale
    ].freeze
    OWNERS = %w[agent operator provider scheduler hive none unknown].freeze

    module_function

    def recoverable_marker?(marker)
      RECOVERABLE_MARKERS.include?(marker.to_s.downcase)
    end
  end
end
