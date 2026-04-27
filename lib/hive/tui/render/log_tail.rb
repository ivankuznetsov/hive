require "curses"

module Hive
  module Tui
    module Render
      # Curses render layer for the log-tail mode. Top line shows the
      # log path; the body draws the trailing N lines that fit; the
      # bottom line is the keymap hint plus an optional `[stale]`
      # annotation when the producing agent's PID is no longer alive.
      #
      # Not unit-tested — pure curses I/O. Behavior is exercised by
      # U11's PTY smoke test indirectly (boot → quit) and by manual
      # dogfood; the testable surface is `LogTail::Tail` itself.
      class LogTail
        def draw(tail, terminal_height, log_path:, claude_pid_alive: nil)
          Curses.clear
          width = Curses.cols
          draw_header(log_path, width)
          draw_body(tail, terminal_height, width)
          draw_footer(claude_pid_alive, width, terminal_height)
          Curses.refresh
        end

        private

        def draw_header(log_path, width)
          Curses.setpos(0, 0)
          Curses.attron(Curses::A_BOLD) { Curses.addstr(truncate(log_path, width)) }
        end

        def draw_body(tail, terminal_height, width)
          available = terminal_height - 2
          rows = tail.lines(available)
          rows.each_with_index do |line, idx|
            Curses.setpos(idx + 1, 0)
            Curses.addstr(truncate(line, width))
          end
        end

        def draw_footer(claude_pid_alive, width, terminal_height)
          Curses.setpos(terminal_height - 1, 0)
          hint = "[q] back to grid"
          hint += "  [stale: claude_pid no longer alive]" if claude_pid_alive == false
          Curses.attron(Curses::A_REVERSE) { Curses.addstr(truncate(hint, width)) }
        end

        def truncate(string, width)
          return "" if string.nil?
          return string if string.length <= width

          string[0, width]
        end
      end
    end
  end
end
