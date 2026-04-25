module Hive
  module Stages
    module Review
      # Post-fix diff guardrail.
      #
      # **STUB** — U13 will implement the real pattern matching against
      # the new commits' diff (curl|wget pipe-to-shell, CI workflow
      # edits, secrets pattern, lockfile changes, permission changes,
      # etc., per the plan's R10 + ADR-020).
      #
      # Phase 4 of the 5-review runner (U9) calls FixGuardrail.run!
      # after the fix agent commits. A :tripped result short-circuits
      # the loop with REVIEW_WAITING reason=fix_guardrail. A :clean
      # result lets the loop proceed to the next Phase 2.
      #
      # The U9 integration boundary is stable; only the body of `run!`
      # changes when U13 ships.
      module FixGuardrail
        Result = Data.define(:status, :matches)

        # Match shape (filled in by U13):
        #   { pattern_name:, file:, line:, snippet:, severity: }
        Match = Data.define(:pattern_name, :file, :line, :snippet, :severity)

        module_function

        def run!(cfg:, ctx:, base_sha:, head_sha:)
          # Skip when explicitly disabled (U13 will respect this knob too).
          enabled = cfg.dig("review", "fix", "guardrail", "enabled")
          return Result.new(status: :skipped, matches: []) if enabled == false

          # Bypass mode (e.g., user re-ran with HIVE_SKIP_FIX_GUARDRAIL=1
          # after manually approving the previous trip).
          bypass = cfg.dig("review", "fix", "guardrail", "bypass")
          return Result.new(status: :skipped, matches: []) if bypass

          # No commits → nothing to scan.
          return Result.new(status: :clean, matches: []) if base_sha == head_sha

          # U13 will replace this with real pattern matching.
          Result.new(status: :clean, matches: [])
        end
      end
    end
  end
end
