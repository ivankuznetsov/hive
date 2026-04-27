require "curses"
require "hive/tui/help"

module Hive
  module Tui
    module Render
      # Centered modal overlay showing `Hive::Tui::Help::BINDINGS`. Any
      # key dismisses. The modal clamps to terminal size so a tiny tty
      # still gets a usable view (rows past the height are dropped; the
      # render loop will repaint the full overlay on resize via the
      # KEY_RESIZE handler).
      #
      # Not unit-tested — pure curses I/O. The unit-tested surface is
      # `Hive::Tui::Help::BINDINGS` itself (cross-check against
      # `Hive::Workflows::VERBS` + uniqueness assertions).
      class HelpOverlay
        MODE_HEADERS = {
          grid: "Grid mode",
          triage: "Triage mode (Enter on a 'review_findings' row)",
          log_tail: "Log tail mode (Enter on an 'agent_running' row)",
          filter: "Filter prompt"
        }.freeze

        # Render the overlay then loop on `getch` until any non-resize key
        # arrives. The render loop set `Curses.timeout = 100` globally so a
        # single `getch` would self-dismiss after 100ms; we ignore nil
        # (timeout) and treat KEY_RESIZE as a redraw, not a dismissal.
        def show
          rows = build_rows
          repaint(rows)
          loop do
            ch = Curses.getch
            next if ch.nil?
            if ch == Curses::KEY_RESIZE
              repaint(rows)
              next
            end
            return
          end
        end

        private

        def repaint(rows)
          Curses.clear
          paint(rows, Curses.lines, Curses.cols)
          Curses.refresh
        end

        def build_rows
          rows = [ "hive tui — keybindings", "" ]
          MODE_HEADERS.each do |mode, header|
            entries = Help::BINDINGS.select { |b| b[:mode] == mode }
            next if entries.empty?

            rows << header
            entries.each { |b| rows << format("  %-7s  %s", b[:key], b[:description]) }
            rows << ""
          end
          rows << "press any key to dismiss"
          rows
        end

        def paint(rows, terminal_height, terminal_width)
          drawable = rows.first(terminal_height - 2)
          start_row = [ (terminal_height - drawable.size) / 2, 0 ].max
          drawable.each_with_index do |line, idx|
            text = truncate(line, terminal_width - 4)
            col = [ (terminal_width - text.length) / 2, 0 ].max
            Curses.setpos(start_row + idx, col)
            Curses.addstr(text)
          end
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
