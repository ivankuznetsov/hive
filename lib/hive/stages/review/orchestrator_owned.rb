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
      # Most entries are dash-terminated because the artifacts carry a
      # `-NN` pass suffix (`errors-01.md`, `fix-success-02.md`), so the
      # prefix probes `basename-`. `suppressed.` is dot-terminated instead:
      # the artifact is a single base-bound `suppressed.md` with no pass
      # suffix, so a `suppressed-` prefix would never match it — but a bare
      # `suppressed` prefix would over-match a hypothetical reviewer file
      # like `suppressed-checks-01.md` and silently drop it. Pinning the
      # dot keeps `suppressed.md` owned while leaving `suppressed-*` (and
      # `suppression-*`) as ordinary reviewer files.
      ORCHESTRATOR_OWNED_PREFIXES = %w[
        escalations-
        ci-blocked
        browser-
        fix-guardrail-
        fix-success-
        errors-
        suppressed.
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
