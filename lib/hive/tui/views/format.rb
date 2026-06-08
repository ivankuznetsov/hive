require "unicode/display_width"

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
      # `ljust`/`rjust`. `truncate` (23 sites) and `display_width` (7) keep
      # their bare names for their existing callers; `wrap` keeps the bare
      # name for consistency with them (it has only the two callers added
      # alongside the scrollable help overlay). All are equally cell-aware.
      #
      # Nil-tolerance contract: every public helper coerces its label
      # through `.to_s`, so a nil label is treated as the empty string
      # rather than raising.
      module Format
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

        # Wrap `label` to `width` cells, one array entry per rendered row.
        # `subsequent_indent` left-pads every continuation row so wrapped
        # text hangs under a fixed column (the help overlay uses this to
        # keep a wrapped description from looking like a fresh row).
        def wrap(label, width, subsequent_indent: 0)
          string = label.to_s
          return [ "" ] if string.empty?

          string.lines.flat_map do |line|
            wrap_line(line.chomp, width, subsequent_indent: subsequent_indent)
          end
        end

        def display_width(label)
          Unicode::DisplayWidth.of(label.to_s)
        end

        # A line that already fits is returned verbatim — internal runs of
        # whitespace (the help cheatsheet's `%-7s` key column + indent) are
        # preserved rather than collapsed to single spaces. Only over-long
        # lines are word-wrapped; a single word wider than `width` is
        # hard-split across rows so no character is dropped (callers that
        # wrap — the now-scrollable help overlay — have unlimited vertical
        # room, so silent ellipsis truncation would be data loss).
        def wrap_line(line, width, subsequent_indent: 0)
          max_width = width.to_i
          return [ "" ] if line.empty?
          return [ line ] if max_width <= 0 || display_width(line) <= max_width

          indent_width = subsequent_indent.to_i.clamp(0, [ max_width / 2, 0 ].max)
          rows = []
          current = +""
          # The first row gets the full width; continuation rows reserve
          # `indent_width` cells for the hanging indent applied below.
          budget = -> { rows.empty? ? max_width : max_width - indent_width }

          line.split(/\s+/).each do |word|
            word = word.dup
            loop do
              candidate = current.empty? ? word : "#{current} #{word}"
              if display_width(candidate) <= budget.call
                current = candidate
                break
              end

              if current.empty?
                # The word alone overflows the row — hard-split a leading
                # cell-bounded chunk and carry the remainder to the next row.
                head = take_cells(word, budget.call)
                head = word.each_grapheme_cluster.first.to_s if head.empty?
                rows << head
                word = word.delete_prefix(head)
                break if word.empty?
              else
                rows << current
                current = +""
              end
            end
          end
          rows << current unless current.empty?

          indent = " " * indent_width
          rows.each_with_index.map { |row, idx| idx.zero? ? row : indent + row }
        end
        private_class_method :wrap_line

        # Internal primitive: a raw cell-bounded cut with no ellipsis.
        # Private so callers can't bypass `truncate`'s ellipsis contract.
        def take_cells(label, max_width)
          remaining = max_width
          label.to_s.each_grapheme_cluster.with_object(+"") do |cluster, result|
            width = display_width(cluster)
            break result if width > remaining

            result << cluster
            remaining -= width
          end
        end
        private_class_method :take_cells
      end
    end
  end
end
