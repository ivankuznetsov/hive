require "hive"

module Hive
  # Top-level TUI module: a Charm bubbletea + lipgloss full-screen,
  # modal dashboard that polls `Hive::Commands::Status#json_payload` at
  # ~1 Hz, renders every active task across registered projects grouped
  # by action label, and dispatches workflow verbs as fresh subprocesses
  # on single-key keystrokes.
  #
  # The TUI is a thin overlay on the existing CLI semantics: it consumes
  # the same JSON `hive status` emits, classifies rows via
  # `Hive::TaskAction`, and shells out for every state mutation. It
  # never writes markers directly and never touches state files outside
  # the existing command surface.
  #
  # MRI-only: the data layer relies on MRI 3.4's GVL for safe
  # cross-thread reads of `@current` snapshots without a Mutex.
  # JRuby/TruffleRuby would need a synchronisation upgrade.
  module Tui
    # Entry point invoked by `Hive::CLI#tui`. Delegates to App.run, which
    # boots `Hive::Tui::App.run_charm` (the only supported backend after
    # U11 of plan #003). The legacy curses path was deleted in U11; the
    # `HIVE_TUI_BACKEND` env var is now recognized only as a
    # graceful-error pointer at the removal — see `App.backend`.
    def self.run
      raise Hive::Error, "hive tui requires MRI Ruby (got #{RUBY_ENGINE})" unless RUBY_ENGINE == "ruby"
      # Boundary parity with `hive tui --json`: both reject with USAGE (64) so a
      # non-tty CI invocation and a misuse `--json` flag share the exit-code surface.
      raise Hive::InvalidTaskPath, "hive tui requires a terminal" unless $stdout.tty?

      require "hive/tui/app"
      Hive::Tui::App.run
    end
  end
end
