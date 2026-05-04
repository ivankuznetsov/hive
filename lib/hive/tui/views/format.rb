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

        # Truncate `label` to `max_width` cells, appending an ellipsis
        # (U+2026) when truncation occurs. `max_width < 2` falls back to
        # a hard cut without ellipsis (no room for the suffix). Used by
        # both ProjectsPane and TasksPane for column/cell fitting.
        # Note: counts code units, not display cells — wide-character
        # cell math is not done here; emoji and CJK can overflow on
        # terminals that render them double-width. Acknowledged.
        def truncate(label, max_width)
          return "" if max_width <= 0
          return label if label.length <= max_width
          return label[0, max_width] if max_width < 2

          "#{label[0, max_width - 1]}…"
        end
      end
    end
  end
end
