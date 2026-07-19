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
      # `ljust`/`rjust`. `truncate`/`display_width` keep their bare names
      # for their many external callers but are equally cell-aware.
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

        def display_width(label)
          Unicode::DisplayWidth.of(label.to_s)
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
