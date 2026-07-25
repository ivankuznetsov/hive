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

    # A max-pass REVIEW_STALE with a concrete escalation artifact represents
    # unresolved reviewer input, not a failed agent launch. Ordinary retry
    # surfaces must not bypass that edit step. The TUI's explicit post-edit
    # `r` gesture may still submit the same coordinator request.
    def intervention_required?(marker:, attrs:, folder:)
      return false unless marker.to_s.downcase == "review_stale"

      normalized = attrs.to_h.transform_keys(&:to_s)
      pass = normalized["pass"].to_s
      return false unless pass.match?(/\A[1-9]\d*\z/)

      File.exist?(
        File.join(folder.to_s, "reviews", "escalations-#{format('%02d', pass.to_i)}.md")
      )
    end
  end
end
