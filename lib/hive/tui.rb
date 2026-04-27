require "hive"

module Hive
  # Top-level TUI module: a curses-based, full-screen, modal dashboard
  # that polls `Hive::Commands::Status#json_payload` at ~1 Hz, renders
  # every active task across registered projects grouped by action label,
  # and dispatches workflow verbs as fresh subprocesses on single-key
  # keystrokes.
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
    # Entry point invoked by `Hive::CLI#tui`. Boots curses, runs the
    # render loop until the user presses `q` (or until the loop
    # otherwise terminates), and tears down. Subsequent units replace
    # the placeholder body with the real polling/render machinery.
    def self.run
      raise Hive::Error, "hive tui requires MRI Ruby (got #{RUBY_ENGINE})" unless RUBY_ENGINE == "ruby"
      raise Hive::Error, "hive tui requires a terminal" unless $stdout.tty?

      require "curses"

      Curses.init_screen
      begin
        Curses.cbreak
        Curses.noecho
        Curses.stdscr.keypad(true)
        Curses.curs_set(0)

        Curses.clear
        Curses.setpos(0, 0)
        Curses.addstr("hive tui — press q to quit")
        Curses.refresh

        loop do
          ch = Curses.getch
          break if ch == "q" || ch == "Q"
        end
      ensure
        Curses.close_screen
      end
    end
  end
end
