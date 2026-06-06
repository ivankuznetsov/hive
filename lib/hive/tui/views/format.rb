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

        def display_width(label)
          Unicode::DisplayWidth.of(label.to_s)
        end

        def take_cells(label, max_width)
          remaining = max_width
          label.to_s.each_grapheme_cluster.with_object(+"") do |cluster, result|
            width = display_width(cluster)
            break result if width > remaining

            result << cluster
            remaining -= width
          end
        end
      end
    end
  end
end
