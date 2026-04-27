require "hive"

module Hive
  module Tui
    # Backend dispatcher. Reads `HIVE_TUI_BACKEND` env var:
    #   unset / "curses" → existing curses run loop (default through U9)
    #   "charm"          → bubbletea + lipgloss path (stub through U9; live in U10+)
    # Anything else raises `Hive::InvalidTaskPath` (exit 64) — same shape as
    # the `--json` rejection at the command boundary.
    #
    # The dispatcher exists for the duration of the migration only. U11
    # deletes it along with the curses code path; the env var is then
    # recognized one more release as a graceful-error pointer at the
    # removal, then dropped entirely.
    module App
      CURSES = "curses".freeze
      CHARM = "charm".freeze
      KNOWN_BACKENDS = [ CURSES, CHARM ].freeze

      module_function

      def run
        case backend
        when CURSES
          Hive::Tui.run_curses
        when CHARM
          run_charm
        end
      end

      def backend
        chosen = ENV.fetch("HIVE_TUI_BACKEND", CURSES).strip
        return chosen if KNOWN_BACKENDS.include?(chosen)

        raise Hive::InvalidTaskPath,
              "unknown HIVE_TUI_BACKEND: #{chosen.inspect} (expected one of: #{KNOWN_BACKENDS.join(', ')})"
      end

      # The charm backend's full implementation lands across U3–U10. Through
      # U2 (verification) and U1 (this scaffold), opting into the charm
      # backend prints a one-line stub and exits cleanly so an early
      # adopter doesn't get a corrupt terminal.
      def run_charm
        warn "[hive tui] HIVE_TUI_BACKEND=charm — backend stub; full implementation lands in U3-U10. " \
             "See docs/plans/2026-04-27-003-refactor-hive-tui-charm-bubbletea-plan.md."
      end
    end
  end
end
