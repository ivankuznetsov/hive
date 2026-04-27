require "hive/tui/snapshot"

module Hive
  module Tui
    # Per-frame view-state for the grid renderer: cursor position,
    # active filter substring, project scope, and the (optional) flash
    # message + timestamp. Pure Ruby — no curses, no I/O — so the cursor
    # math (move/clamp/wrap), filter and scope re-application, and flash
    # decay are unit-testable in isolation.
    #
    # Mutating methods return `self` rather than a new instance: the
    # render loop holds a single GridState across frames, so cloning per
    # keystroke would be wasted work. Snapshot, in contrast, is frozen
    # and returns new instances from filter/scope — that's its
    # responsibility (one frozen JSON view), not GridState's.
    #
    # Cursor convention: `[project_idx, row_idx]` against the
    # *scope-and-filter-applied* snapshot (see `#visible_snapshot`). nil
    # means "nothing selected" — used when the visible grid has zero
    # rows, so the renderer can omit the highlight bar entirely.
    class GridState
      DEFAULT_FLASH_TTL_SECONDS = 5.0

      attr_reader :cursor, :filter, :scope, :flash_message

      def initialize
        @cursor = [ 0, 0 ]
        @filter = nil
        @scope = 0
        @flash_message = nil
        @flash_at = nil
      end

      # Composed snapshot the renderer draws from. Apply scope first
      # (collapses to a single project) so the filter operates on the
      # narrower set and the cursor's project_idx is stable against the
      # visible projects list.
      def visible_snapshot(snapshot)
        snapshot.scope_to_project_index(@scope).filter_by_slug(@filter)
      end

      # Returns the row currently under the cursor against the
      # scope-and-filter-applied snapshot, or nil if the visible grid is
      # empty / cursor is nil.
      def at_cursor(snapshot)
        return nil if @cursor.nil?

        visible_snapshot(snapshot).row_at(@cursor)
      end

      # Cursor moves one row down within the same project; on overflow,
      # it advances to the first row of the next project that has any
      # visible rows. Stays clamped at the last row of the last
      # non-empty project rather than wrapping back to the top — wrap
      # would mask the grid's scroll boundary.
      def move_cursor_down(snapshot)
        visible = visible_snapshot(snapshot)
        return self if @cursor.nil?

        project_idx, row_idx = @cursor
        return self unless project_idx.between?(0, visible.projects.size - 1)

        rows = visible.projects[project_idx].rows
        if row_idx + 1 < rows.size
          @cursor = [ project_idx, row_idx + 1 ]
        else
          next_idx = next_non_empty_project_idx(visible, project_idx + 1)
          @cursor = [ next_idx, 0 ] if next_idx
        end
        self
      end

      # Cursor moves one row up within the same project; on underflow,
      # it jumps to the last row of the previous project that has any
      # visible rows. Stays clamped at [0, 0] of the first non-empty
      # project rather than wrapping to the bottom.
      def move_cursor_up(snapshot)
        visible = visible_snapshot(snapshot)
        return self if @cursor.nil?

        project_idx, row_idx = @cursor
        return self unless project_idx.between?(0, visible.projects.size - 1)

        if row_idx > 0
          @cursor = [ project_idx, row_idx - 1 ]
        else
          prev_idx = prev_non_empty_project_idx(visible, project_idx - 1)
          if prev_idx
            last = visible.projects[prev_idx].rows.size - 1
            @cursor = [ prev_idx, last ]
          end
        end
        self
      end

      # nil/empty filter clears it; cursor returns to [0, 0] of the
      # first visible project (or nil if the visible grid is empty).
      # Otherwise applies the filter and re-clamps the cursor to the
      # nearest non-empty project — never leaves cursor pointing into a
      # zero-row project when matches exist elsewhere.
      def set_filter(string, snapshot)
        @filter = (string.nil? || string.empty?) ? nil : string
        @cursor = first_visible_cursor(visible_snapshot(snapshot))
        self
      end

      # `n == 0` clears scope (all projects). Out-of-range still flips
      # the scope (Snapshot returns an empty-projects view) so the
      # renderer can show "no project at that index"; cursor goes nil.
      def set_scope(n, snapshot)
        @scope = n
        @cursor = first_visible_cursor(visible_snapshot(snapshot))
        self
      end

      # Sets a one-line message and timestamps it. The render loop calls
      # this from action handlers; `flash_active?` then decides whether
      # to draw the message or fall back to the help hint.
      def flash!(message, now: Time.now)
        @flash_message = message
        @flash_at = now
        self
      end

      def flash_active?(now: Time.now, ttl_seconds: DEFAULT_FLASH_TTL_SECONDS)
        return false if @flash_message.nil? || @flash_at.nil?

        (now - @flash_at) <= ttl_seconds
      end

      private

      # Walk visible projects forward from `start_idx` looking for the
      # first project with at least one row. Returns nil when the tail
      # of the grid is empty so the caller can clamp instead of wrap.
      def next_non_empty_project_idx(visible, start_idx)
        idx = start_idx
        while idx < visible.projects.size
          return idx unless visible.projects[idx].rows.empty?

          idx += 1
        end
        nil
      end

      # Symmetric of next_non_empty_project_idx walking backward.
      def prev_non_empty_project_idx(visible, start_idx)
        idx = start_idx
        while idx >= 0
          return idx unless visible.projects[idx].rows.empty?

          idx -= 1
        end
        nil
      end

      # First [project_idx, 0] with visible rows, or nil if the grid is
      # empty. Used after scope/filter changes so the cursor never
      # points at a zero-row project when matches exist elsewhere.
      def first_visible_cursor(visible)
        first = next_non_empty_project_idx(visible, 0)
        first.nil? ? nil : [ first, 0 ]
      end
    end
  end
end
