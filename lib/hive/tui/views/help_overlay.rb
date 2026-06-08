require "lipgloss"
require "hive/tui/help"
require "hive/tui/styles"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      # Pure view function: `Views::HelpOverlay.render(model) → String`.
      # Renders the keybinding cheatsheet from `Hive::Tui::Help::BINDINGS`
      # grouped by mode header, wrapped in a Lipgloss bordered box.
      #
      # When `model.mode == :help`, U10's view dispatcher returns this
      # output as the full frame. Composing it as an overlay over the
      # underlying grid is a future polish — for v1 a full-screen modal
      # matches the curses behavior (curses cleared the screen before
      # painting the overlay, so users never saw underlying content).
      module HelpOverlay
        MODE_HEADERS = {
          grid: "Grid mode",
          log_tail: "Log tail mode (Enter on an 'agent_running' row)",
          token_stats: "Token stats mode (T)",
          filter: "Filter prompt",
          idea_preview: "Idea preview (i)",
          new_idea: "New-idea prompt (n)"
        }.freeze

        TITLE = "hive tui — keybindings".freeze
        # Close affordance leads so it survives footer truncation at the
        # minimum width (≈40 cols), where the scroll-key hint is clipped.
        DISMISS_HINT = "Esc/? close · ↑/↓ j/k PgUp/PgDn scroll".freeze
        TOO_SMALL_MESSAGE = "Terminal too small for help (need 10×40)".freeze
        # Degenerate-size fallback (rows ≈ 1, or narrow-and-short): the
        # full message can't fit, so collapse to the one piece of info the
        # user needs — the minimum dimensions — rather than truncating to
        # "Terminal too…" and dropping the guidance entirely.
        TOO_SMALL_FALLBACK = "need 10×40".freeze
        MIN_ROWS = 10
        MIN_COLS = 40
        BORDER_ROWS = 2
        BORDER_COLS = 2
        PADDING_ROWS = 2
        PADDING_COLS = 4
        OUTER_MARGIN_COLS = 4
        SCROLLBAR_WIDTH = 1
        MIN_CONTENT_WIDTH = 8
        # Column the description starts in, matching `build_lines`'
        # `format("  %-7s  %s", …)`: 2-space indent + 7-wide key + 2 gap.
        # Wrapped continuation rows of a binding hang here so they don't
        # read as a fresh key entry.
        DESCRIPTION_INDENT = 11

        # One wrapped content row: its text plus whether it is a section
        # header (title / mode header). Named so readers don't destructure
        # an anonymous `[String, Boolean]` tuple and so the styling flag
        # isn't boolean-blind.
        Segment = Data.define(:text, :header) do
          def header? = header
        end
        PADDING_SEGMENT = Segment.new(text: "", header: false).freeze

        module_function

        def render(model)
          return render_too_small(model) if too_small?(model)

          rows = scrollable_rows(model)
          content = content_rows(model)
          max_offset = max_scroll_offset(model, content.length)
          offset = [ [ model.help_scroll_offset.to_i, 0 ].max, max_offset ].min
          # Only pad to the full viewport height while the content
          # overflows (so the scrollbar track stays put during scroll).
          # When everything fits, leave the box compact rather than
          # ballooning a short cheatsheet into a near-empty full-screen box.
          overflow = content.length > rows
          visible = Array(content[offset, rows]).first(rows)
          visible += Array.new(rows - visible.length, PADDING_SEGMENT) if overflow && visible.length < rows

          body = Lipgloss.join_vertical(
            Lipgloss::TOP,
            scroll_window(
              model,
              visible,
              scrollbar_lines(total: content.length, rows: visible.length, offset: offset)
            ),
            footer_line(model)
          )

          Lipgloss::Style.new
                         .border(Lipgloss::Border::NORMAL)
                         .padding(1, 2)
                         .width(box_width(model))
                         .render(body)
        end

        # @api private — exposed for tests.
        def build_lines
          rows = [ TITLE, "" ]
          MODE_HEADERS.each do |mode, header|
            entries = Help::BINDINGS.select { |b| b[:mode] == mode }
            next if entries.empty?

            rows << header
            entries.each { |b| rows << format("  %-7s  %s", b[:key], b[:description]) }
            rows << ""
          end
          rows.pop while rows.last == ""
          rows
        end

        def content_lines(model)
          content_rows(model).map(&:text)
        end

        # Wrapped content paired with a header flag. The text stays plain
        # so it feeds the cell-width helpers (wrap/ljust/scrollbar) without
        # ANSI skewing the math; `Styles::HEADER` is applied later, after
        # padding, in `scroll_window`. Headers are kept bold so the title
        # and per-mode sections read as a hierarchy, matching the sibling
        # panes (archive/projects/tasks) that style after width-bounding.
        # @api private — exposed for tests.
        #
        # Memoized by inner content width: both the render path and the
        # Update-layer scroll clamp (`max_scroll_offset`) ask for the
        # wrapped content on every keystroke, and the wrap depends only on
        # the width (the bindings are a frozen constant). Caching by width
        # keeps a per-scroll-key full re-wrap from running. The TUI render
        # and Update run on the same loop thread, so the plain Hash is safe.
        def content_rows(model)
          width = inner_content_width(model)
          (@content_rows_cache ||= {})[width] ||= build_content_rows(width)
        end

        def build_content_rows(width)
          build_lines.flat_map do |line|
            header = header_line?(line)
            indent = header ? 0 : DESCRIPTION_INDENT
            Format.wrap(line, width, subsequent_indent: indent)
                  .map { |segment| Segment.new(text: segment, header: header) }
          end
        end
        private_class_method :build_content_rows

        def header_line?(line)
          line == TITLE || MODE_HEADERS.value?(line)
        end

        def viewport_rows(model)
          [ model.rows.to_i - BORDER_ROWS - PADDING_ROWS, 1 ].max
        end

        def scrollable_rows(model)
          [ viewport_rows(model) - 1, 1 ].max
        end

        def inner_content_width(model)
          [
            box_width(model) - PADDING_COLS - SCROLLBAR_WIDTH,
            MIN_CONTENT_WIDTH
          ].max
        end

        # Single source of the scroll bound. `render` passes the length of
        # the content it already wrapped so the bound isn't recomputed from
        # a second wrap; the Update-layer clamp calls it with no total and
        # lets it derive the length (cheap via the `content_rows` memo).
        def max_scroll_offset(model, total_rows = content_rows(model).length)
          [ total_rows - scrollable_rows(model), 0 ].max
        end

        def box_width(model)
          [ model.cols.to_i - OUTER_MARGIN_COLS, MIN_COLS - BORDER_COLS ].max
        end

        def render_too_small(model)
          width = [ model.cols.to_i, 1 ].max
          height = [ model.rows.to_i, 1 ].max
          lines = Format.wrap(TOO_SMALL_MESSAGE, width)
          lines = [ Format.truncate(TOO_SMALL_FALLBACK, width) ] if lines.length > height

          top = [ (height - lines.length) / 2, 0 ].max
          bottom = [ height - top - lines.length, 0 ].max
          blank = " " * width
          centered = lines.map { |line| center_line(line, width) }
          ([ blank ] * top + centered + [ blank ] * bottom).join("\n")
        end

        def too_small?(model)
          model.rows.to_i < MIN_ROWS || model.cols.to_i < MIN_COLS
        end

        def scroll_window(model, visible, scrollbar)
          width = inner_content_width(model)
          content = visible.map do |segment|
            padded = Format.ljust_cells(segment.text, width)
            segment.header? ? Styles::HEADER.render(padded) : padded
          end
          Lipgloss.join_horizontal(
            Lipgloss::TOP,
            Lipgloss.join_vertical(Lipgloss::TOP, *content),
            Lipgloss.join_vertical(Lipgloss::TOP, *scrollbar)
          )
        end

        def scrollbar_lines(total:, rows:, offset:)
          return Array.new(rows, " ") if total <= rows

          max_offset = [ total - rows, 0 ].max
          thumb_size = [ (rows.to_f * rows / total).ceil, 1 ].max
          thumb_size = [ thumb_size, rows ].min
          thumb_top = if max_offset.zero?
            0
          else
            ((offset.to_f / max_offset) * (rows - thumb_size)).round
          end

          rows.times.map do |row|
            row.between?(thumb_top, thumb_top + thumb_size - 1) ? "█" : "│"
          end
        end

        def footer_line(model)
          Styles::HINT.render(Format.truncate(DISMISS_HINT, box_width(model) - PADDING_COLS))
        end

        def center_line(line, width)
          cells = Format.display_width(line)
          left = [ (width - cells) / 2, 0 ].max
          right = [ width - cells - left, 0 ].max
          (" " * left) + line + (" " * right)
        end
      end
    end
  end
end
