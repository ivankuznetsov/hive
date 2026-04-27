require "hive/findings"

module Hive
  module Tui
    # Pure command-builder + cursor state for the findings triage mode.
    # Holds a list of `Hive::Findings::Finding` records, the cursor index
    # into that list, and produces the argv arrays the render loop hands
    # to `Subprocess.run_quiet!` / `takeover!`. No curses, no I/O — every
    # branch is unit-testable without a tty.
    #
    # The state is mutated in place across frames (cursor moves, findings
    # reload after a toggle) so the loop holds a single instance per
    # triage session, mirroring `GridState`'s ownership model.
    class TriageState
      # Title-prefix slice used by `relocate_cursor` to re-find the prior
      # cursor finding after a document reload. 32 chars is long enough
      # to disambiguate review-pass titles in practice (the plan calls
      # this out as a residual risk if two findings share the prefix).
      TITLE_PREFIX_LEN = 32

      attr_reader :findings, :cursor, :slug

      def initialize(slug:, findings:)
        @slug = slug
        @findings = findings
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

      def develop_command
        [ "hive", "develop", @slug, "--from", "4-execute" ]
      end

      # `direction` is `:accept` or `:reject`; anything else raises so the
      # caller (KeyMap dispatch) gets a loud signal rather than a silent
      # noop on a typo.
      def bulk_command(direction)
        raise ArgumentError, "bulk_command direction must be :accept or :reject" unless %i[accept reject].include?(direction)

        [ "hive", "#{direction}-finding", @slug, "--all" ]
      end

      # After a document reload, find the index of the previously-current
      # finding by `(severity, title-prefix)`. Updates `@findings` and
      # `@cursor` in place; returns one of:
      #   :unchanged — same finding lives at the same index in new list
      #   :relocated — same finding found at a different index
      #   :reset     — no match; cursor reset to 0 (caller should flash)
      # When two new findings share the same key, snaps to the first
      # match (residual risk documented in the plan).
      def relocate_cursor(new_findings)
        prior = current_finding
        @findings = new_findings

        if prior.nil?
          @cursor = 0
          return :reset
        end

        key = lookup_key_for(prior)
        new_index = new_findings.index { |f| lookup_key_for(f) == key }

        if new_index.nil?
          @cursor = 0
          :reset
        elsif new_index == @cursor && new_findings[new_index] == prior
          :unchanged
        else
          @cursor = new_index
          :relocated
        end
      end

      private

      def lookup_key_for(finding)
        [ finding.severity, finding.title.to_s[0, TITLE_PREFIX_LEN] ]
      end
    end
  end
end
