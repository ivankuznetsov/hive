require "unicode/display_width"

require "hive/tui/text"

module Hive
  module Tui
    module Views
      # Shared formatting helpers used by multiple view modules. Lifted
      # out of v1's `Views::Grid` so the new v2 `Views::TasksPane` can
      # reuse the canonical `hive status` age humanization without
      # duplicating it. Keeps the two surfaces from disagreeing on what
      # "5m" means — every view that displays a row's mtime/age routes
      # through this module.
      # Naming note: the `_cells` suffix (`ljust_cells`/`rjust_cells`)
      # distinguishes the cell-aware padders from String's column-naive
      # `ljust`/`rjust`. `truncate`/`display_width` keep their bare names
      # for their many external callers but are equally cell-aware.
      #
      # Nil-tolerance contract: every public helper coerces its label
      # through `.to_s`, so a nil label is treated as the empty string
      # rather than raising.
      module Format
        # Reuse Text's ECMA-48 CSI matcher: SGR styling (Lipgloss `render`)
        # and cursor/erase sequences must never be measured or cut as
        # visible cells.
        CSI_PATTERN = Hive::Tui::Text::ANSI_CSI_PATTERN

        # SGR-specific shape of a CSI sequence (final byte `m`) plus the
        # canonical reset, used to track whether a cut strands an open
        # style that then needs a trailing reset re-appended.
        SGR_SEQUENCE = /\A\e\[[\d;?]*[ -\/]*m\z/.freeze
        RESET_SEQUENCE = "\e[0m".freeze

        # Token stream for cell cutting: one whole CSI sequence, one run
        # of non-ESC bytes, or a lone ESC that never formed a sequence.
        TOKEN_PATTERN = /#{CSI_PATTERN}|[^\e]+|\e/.freeze

        module_function

        # Single-place humaniser; matches `hive status` text output so
        # both surfaces never disagree on what "5m" means.
        def age(age_seconds)
          seconds = age_seconds.to_i
          return "#{seconds}s" if seconds < 60
          return "#{seconds / 60}m" if seconds < 3600
          return "#{seconds / 3600}h" if seconds < 86_400

          "#{seconds / 86_400}d"
        end

        # Truncate `label` to `max_width` terminal cells, appending an
        # ellipsis (U+2026) when truncation occurs. `max_width < 2`
        # falls back to a hard cut without ellipsis (no room for the
        # suffix). Used by pane/table renderers for column fitting.
        # Truncation is ANSI-aware: escape sequences carry zero visible
        # width and survive cuts intact (a stranded SGR opener gets its
        # reset re-appended), so styled lines can be truncated safely.
        def truncate(label, max_width)
          return "" if max_width <= 0

          string = label.to_s
          return string if display_width(string) <= max_width
          return take_cells(string, max_width) if max_width < 2

          "#{take_cells(string, max_width - 1)}…"
        end

        def ljust_cells(label, width)
          string = truncate(label, width)
          string + (" " * [ width - display_width(string), 0 ].max)
        end

        def rjust_cells(label, width)
          string = truncate(label, width)
          (" " * [ width - display_width(string), 0 ].max) + string
        end

        # Cell-aware tail: keep as many trailing cells of `label` as fit in
        # `max_width`, dropping whole leading grapheme clusters that no longer
        # fit. Complement of the private `take_cells` cut — used by sliding
        # input surfaces (e.g. the filter prompt) that must show the END of a
        # long buffer within a fixed cell budget.
        def tail_cells(label, max_width)
          remaining = max_width.to_i
          kept = []
          label.to_s.each_grapheme_cluster.reverse_each do |cluster|
            cluster_width = display_width(cluster)
            break if cluster_width > remaining

            kept << cluster
            remaining -= cluster_width
          end
          kept.reverse.join
        end

        def wrap(label, width)
          string = label.to_s
          return [ "" ] if string.empty?

          string.lines.flat_map { |line| wrap_line(line.chomp, width) }
        end

        # Fixed-width character chunks for cursor-aware and read-only text
        # surfaces. Always return one row so an empty composer has a cursor
        # target and an empty preview line remains visible.
        def character_chunks(label, capacity)
          string = label.to_s
          return [ "" ] if string.empty?

          chunks = []
          offset = 0
          while offset < string.length
            chunks << string[offset, capacity].to_s
            offset += capacity
          end
          chunks
        end

        def viewport_start(total:, capacity:, selected_index:)
          return 0 if total <= capacity

          selected = selected_index.clamp(0, total - 1)
          selected < capacity ? 0 : [ selected - capacity + 1, total - capacity ].min
        end

        # Visible terminal cells only — ANSI CSI escapes are stripped
        # before measuring, so a styled string reports its on-screen
        # width rather than its byte-inflated one.
        def display_width(label)
          Unicode::DisplayWidth.of(strip_ansi(label.to_s))
        end

        def strip_ansi(text)
          text.to_s.gsub(CSI_PATTERN, "")
        end

        def wrap_line(line, width)
          max_width = width.to_i
          return [ "" ] if line.empty?
          return [ truncate(line, max_width) ] if max_width <= 8

          rows = []
          current = +""
          line.split(/\s+/).each do |word|
            candidate = current.empty? ? word : "#{current} #{word}"
            if display_width(candidate) <= max_width
              current = candidate
            else
              rows << truncate(current, max_width) unless current.empty?
              current = word
            end
          end
          rows << truncate(current, max_width) unless current.empty?
          rows.empty? ? [ "" ] : rows
        end
        private_class_method :wrap_line

        # Internal primitive: a raw cell-bounded cut with no ellipsis.
        # Private so callers can't bypass `truncate`'s ellipsis contract.
        # Escape sequences are preserved free-of-charge even past the cut
        # point — most importantly a trailing SGR reset — so a truncated
        # styled line cannot bleed reverse video / colour into later
        # output. A cut that strands an open SGR style gets a reset
        # appended before returning. The cut is a strict prefix cut: once
        # a visible grapheme does not fit, no later text token may leak
        # through, even when mid-line escapes split the line into several
        # visible runs.
        def take_cells(label, max_width)
          remaining = max_width
          result = +""
          style_open = false
          exhausted = false
          label.to_s.scan(TOKEN_PATTERN) do |token|
            if token.start_with?("\e")
              result << token
              style_open = token != RESET_SEQUENCE if token.match?(SGR_SEQUENCE)
            else
              token.each_grapheme_cluster do |cluster|
                width = display_width(cluster)
                if exhausted || width > remaining
                  exhausted = true
                  break
                end

                result << cluster
                remaining -= width
              end
            end
          end
          result << RESET_SEQUENCE if style_open
          result
        end
        private_class_method :take_cells
      end
    end
  end
end
