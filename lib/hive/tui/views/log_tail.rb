require "lipgloss"
require "hive/tui/styles"

module Hive
  module Tui
    module Views
      # Pure view function: `Views::LogTail.render(model) → String`.
      # Mirrors `Render::LogTail#draw` — top line is the log path; body
      # is the trailing N lines that fit; bottom line is `[q] back`
      # plus an optional `[stale: claude_pid no longer alive]` annotation.
      #
      # `model.tail_state` is expected to expose `#path`, `#claude_pid_alive`,
      # and `#lines(n)`. The existing `Hive::Tui::LogTail::Tail` class
      # provides these — wrap or extend it in U10 to surface `path` and
      # `claude_pid_alive` if it doesn't already; the view is agnostic
      # to whether it's a full Tail or a wrapping struct.
      module LogTail
        FOOTER_HINT_BACK = "[q] back to grid".freeze
        STALE_ANNOTATION = "  [stale: claude_pid no longer alive]".freeze

        module_function

        def render(model)
          state = model.tail_state
          return "" if state.nil?

          # Reserve one row for the path, one for the footer; body fills
          # the rest. `model.rows` defaults to 24 so we always leave at
          # least one body line even on a tiny terminal.
          available = [ model.rows.to_i - 2, 1 ].max

          path_line = Styles::HEADER.render(truncate(state.path.to_s, model.cols.to_i))

          body_lines = state.lines(available).map { |line| truncate(line, model.cols.to_i) }
          # Pad up to `available` lines so the footer stays anchored at
          # the bottom even when the log has fewer lines than the body
          # height — Bubble Tea diffing only paints what's there, but a
          # consistent layout makes the footer position stable across
          # frames.
          padded_body = body_lines + Array.new([ available - body_lines.size, 0 ].max, "")

          footer_text = FOOTER_HINT_BACK
          footer_text += STALE_ANNOTATION if state.claude_pid_alive == false
          footer = Styles::CURSOR_HIGHLIGHT.render(truncate(footer_text, model.cols.to_i))

          Lipgloss.join_vertical(Lipgloss::TOP, path_line, *padded_body, footer)
        end

        def truncate(string, width)
          return "" if string.nil?
          return string if width <= 0 || string.length <= width

          string[0, width]
        end
      end
    end
  end
end
