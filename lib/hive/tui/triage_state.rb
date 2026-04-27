require "hive/findings"

module Hive
  module Tui
    # Pure command-builder + cursor state for the findings triage mode.
    # Holds a list of `Hive::Findings::Finding` records, the cursor index
    # into that list, and produces the argv arrays BubbleModel hands to
    # `Subprocess.run_quiet!` (per-finding toggles) or
    # `Subprocess.takeover_command` (`d` to dispatch develop). No I/O —
    # every branch is unit-testable without a tty.
    #
    # The state is mutated in place across frames (cursor moves, findings
    # reload after a toggle) so the loop holds a single instance per
    # triage session — the Charm Model carries it on `model.triage_state`
    # and BubbleModel mutates it directly when reload-after-toggle fires.
    class TriageState
      # Title-prefix slice used by `relocate_cursor` to re-find the prior
      # cursor finding after a document reload. 32 chars is long enough
      # to disambiguate review-pass titles in practice (the plan calls
      # this out as a residual risk if two findings share the prefix).
      TITLE_PREFIX_LEN = 32

      attr_reader :findings, :cursor, :slug, :review_path

      # `review_path` is optional so legacy callers that built a
      # TriageState without it still construct cleanly; in production
      # `Hive::Tui::BubbleModel#open_findings` always supplies it
      # because views read `state.review_path` for the header.
      def initialize(slug:, findings:, review_path: nil)
        @slug = slug
        @findings = findings
        @review_path = review_path
        @cursor = 0
      end

      def cursor_down
        return self if @findings.empty?

        @cursor = [ @cursor + 1, @findings.size - 1 ].min
        self
      end

      def cursor_up
        @cursor = [ @cursor - 1, 0 ].max
        self
      end

      def current_finding
        return nil if @findings.empty?

        @findings[@cursor]
      end

      # Returns argv for the inverse of the finding's current state:
      # accepted -> reject, not-accepted -> accept. Pure construction;
      # never touches a subprocess.
      def toggle_command(finding)
        raise ArgumentError, "toggle_command requires a finding" if finding.nil?

        verb = finding.accepted ? "reject-finding" : "accept-finding"
        [ "hive", verb, @slug, finding.id.to_s ]
      end

      # `direction` is `:accept` or `:reject`; anything else raises so the
      # caller (KeyMap dispatch) gets a loud signal rather than a silent
      # noop on a typo.
      def bulk_command(direction)
        raise ArgumentError, "bulk_command direction must be :accept or :reject" unless %i[accept reject].include?(direction)

        [ "hive", "#{direction}-finding", @slug, "--all" ]
      end

      # After a document reload, find the index of the previously-current
      # finding using a layered lookup:
      #   1. If the prior finding's `id` exists in the new list, prefer
      #      that exact identity match (fastest disambiguation when the
      #      reviewer rewrote titles or shifted severities).
      #   2. Otherwise, look up by `(severity, title-prefix)`. When
      #      multiple new findings share that key, prefer the one
      #      closest to the prior cursor index so the highlight tracks
      #      the user's mental position rather than first-match.
      #   3. If no match, reset cursor to 0 and return `:reset`.
      #
      # Updates `@findings` and `@cursor` in place; returns one of:
      #   :unchanged — same finding lives at the same index in new list
      #   :relocated — same finding found at a different index
      #   :reset     — no match; cursor reset to 0 (caller should flash)
      def relocate_cursor(new_findings)
        prior = current_finding
        prior_index = @cursor
        @findings = new_findings

        if prior.nil?
          @cursor = 0
          return :reset
        end

        new_index = locate_by_id(prior, new_findings) ||
                    locate_by_prefix(prior, prior_index, new_findings)

        if new_index.nil?
          @cursor = 0
          :reset
        elsif new_index == prior_index && new_findings[new_index] == prior
          :unchanged
        else
          @cursor = new_index
          :relocated
        end
      end

      private

      def locate_by_id(prior, new_findings)
        return nil if prior.id.nil?

        new_findings.index { |f| f.id == prior.id }
      end

      # Closest-by-index match among new findings sharing the prior key.
      # When two candidates are equidistant (e.g. prior_index=2, matches
      # at 0 and 4), `min_by` keeps the first encountered, which is
      # earliest-in-list — a stable, predictable tiebreak.
      def locate_by_prefix(prior, prior_index, new_findings)
        key = lookup_key_for(prior)
        candidates = new_findings.each_index.select { |i| lookup_key_for(new_findings[i]) == key }
        return nil if candidates.empty?

        candidates.min_by { |i| (i - prior_index).abs }
      end

      def lookup_key_for(finding)
        [ finding.severity, finding.title.to_s[0, TITLE_PREFIX_LEN] ]
      end
    end
  end
end
