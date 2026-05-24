module Hive
  module Stages
    module Review
      # Single source of truth for the orchestrator-owned filename
      # prefixes inside `reviews/`. Both `Hive::Stages::Review` and
      # `Hive::Stages::Review::Triage` consume this — previously each
      # carried its own copy and the two lists had to stay in lockstep
      # by hand. Loaded from a leaf file with no other dependencies so
      # both parents can require it without introducing a circular
      # require.
      ORCHESTRATOR_OWNED_PREFIXES = %w[
        escalations-
        ci-blocked
        browser-
        fix-guardrail-
        fix-success-
        errors-
      ].freeze

      module_function

      # True for filenames that originate from a reviewer (not the
      # orchestrator). Used by every consumer of `reviews/*.md`.
      def reviewer_file?(name)
        ORCHESTRATOR_OWNED_PREFIXES.none? { |p| name.start_with?(p) }
      end
    end
  end
end
