require "hive"
require "hive/tui/model"
require "hive/tui/messages"
require "hive/tui/subprocess"

module Hive
  module Tui
    # MVU Update function. Single dispatch point for every state
    # transition: `Update.apply(model, message) → [model, cmd]`.
    #
    # Pure Ruby — no Bubbletea runtime, no rendering, no I/O. The
    # returned Cmd is either nil (no side effect) or a Bubbletea
    # command value the runner interprets (e.g., `Bubbletea.quit`).
    # This means Update is unit-testable without a terminal.
    #
    # Adding a new transition:
    #   1. Define the Message in `Hive::Tui::Messages`
    #   2. Add a branch here
    #   3. Add a test case in `test/unit/tui/update_test.rb`
    #
    # Keystroke handling lands in U5 (KeyMap returns Messages). This
    # skeleton handles the framework-level messages (window resize,
    # snapshot poll, subprocess exit, terminate) and the filter-prompt
    # text-editing messages.
    module Update
      module_function

      def apply(model, message)
        case message
        when Messages::WindowSized
          [ apply_window_sized(model, message), nil ]
        when Messages::SnapshotArrived
          [ apply_snapshot_arrived(model, message), nil ]
        when Messages::PollFailed
          [ apply_poll_failed(model, message), nil ]
        when Messages::SubprocessExited
          [ apply_subprocess_exited(model, message), nil ]
        when Messages::Tick
          [ apply_tick(model), nil ]
        when Messages::YieldTick
          # Pure no-op — the GVL yield happens in the tick callback
          # itself (see BubbleModel#yield_tick_cmd). Update's job is
          # to leave the model unchanged and let BubbleModel
          # reschedule the recurring tick.
          [ model, nil ]
        when Messages::FilterCharAppended
          [ apply_filter_char_appended(model, message), nil ]
        when Messages::FilterCharDeleted
          [ apply_filter_char_deleted(model), nil ]
        when Messages::FilterCommitted
          [ apply_filter_committed(model), nil ]
        when Messages::FilterCancelled
          [ apply_filter_cancelled(model), nil ]
        when Messages::TerminateRequested
          [ model, terminate_command ]
        when Messages::Flash
          [ apply_flash(model, message), nil ]
        when Messages::CursorDown
          [ apply_cursor_down(model), nil ]
        when Messages::CursorUp
          [ apply_cursor_up(model), nil ]
        when Messages::TriageCursorDown
          [ apply_triage_cursor_down(model), nil ]
        when Messages::TriageCursorUp
          [ apply_triage_cursor_up(model), nil ]
        when Messages::ShowHelp
          [ apply_show_help(model), nil ]
        when Messages::OpenFilterPrompt
          [ apply_open_filter_prompt(model), nil ]
        when Messages::Back
          [ apply_back(model), nil ]
        when Messages::ProjectScope
          [ apply_project_scope(model, message), nil ]
        when Messages::Noop
          [ model, nil ]
        when Messages::KeyPressed
          # Translation lives in `BubbleModel#update` (U10): KeyMap.message_for
          # is called there before delegating to Update.apply. KeyPressed
          # arriving here means the runner sent it raw without translation —
          # treat as noop so a misconfigured wiring doesn't crash the loop.
          [ model, nil ]
        else
          # Unknown messages flow through unchanged. Future-compat with
          # framework messages we don't yet care about (FocusMessage,
          # BlurMessage, MouseMessage if mouse ever gets enabled).
          # DispatchCommand / OpenFindings / OpenLogTail / Bulk* /
          # ToggleFinding intentionally fall through here — they require
          # I/O or a runner reference and are handled in BubbleModel
          # before delegating to Update.
          [ model, nil ]
        end
      end

      # Returned for TerminateRequested. Indirected so the test layer
      # can verify the contract without requiring Bubbletea to be
      # loaded. Production sets this to `Bubbletea.quit` once Bubbletea
      # is required (in `Hive::Tui::App.run_charm`).
      def terminate_command
        return Bubbletea.quit if defined?(Bubbletea)

        # Sentinel for tests — App.run_charm (U10) wraps Update with the
        # Bubbletea-aware indirection so this branch only fires in unit
        # tests where Bubbletea isn't loaded.
        :__terminate_sentinel__
      end

      def apply_window_sized(model, msg)
        model.with(cols: msg.cols, rows: msg.rows)
      end

      # Successful poll → store snapshot, clear last_error so the
      # stalled banner stops showing. Re-clamps the cursor when the new
      # snapshot's visible rows make the prior coords invalid: a poll
      # that drops the last row of the cursor's project, or shrinks the
      # project list past the cursor's project_idx, would otherwise
      # leave model.cursor pointing at hidden rows. j/k subsequently
      # noops because apply_cursor_* refuses to move from an invalid
      # cursor. Preserve cursor when still valid (avoids snapping the
      # user's selection on every benign poll).
      def apply_snapshot_arrived(model, msg)
        new_model = model.with(snapshot: msg.snapshot, last_error: nil)
        visible = visible_snapshot(new_model)
        return new_model if visible.nil?

        new_model.with(cursor: reclamp_cursor(visible, new_model.cursor))
      end

      # Keep the cursor coords if they still point at an existing row
      # in the visible snapshot; otherwise jump to the first visible
      # row (or nil when the visible grid is empty).
      def reclamp_cursor(visible, current)
        return first_visible_cursor(visible) if current.nil?

        project_idx, row_idx = current
        if project_idx.between?(0, visible.projects.size - 1) &&
           row_idx.between?(0, visible.projects[project_idx].rows.size - 1)
          return current
        end

        first_visible_cursor(visible)
      end

      # Failed poll → keep prior snapshot, record error for renderer
      # staleness display. Mirrors StateSource's existing rescue pattern.
      def apply_poll_failed(model, msg)
        model.with(last_error: msg.error)
      end

      # Subprocess exit — non-zero flashes the exit code in the status
      # line for the flash TTL. Zero exits silently (success path).
      def apply_subprocess_exited(model, msg)
        return model if msg.exit_code.nil? || msg.exit_code.zero?

        model.with(
          flash: "`#{msg.verb}` exited #{msg.exit_code} — tail #{Hive::Tui::Subprocess.log_path}",
          flash_set_at: Time.now
        )
      end

      # Periodic age-out — clears expired flash messages so the status
      # line falls back to the default hint after the TTL.
      def apply_tick(model)
        return model if model.flash_set_at.nil?
        return model if model.flash_active?

        model.with(flash: nil, flash_set_at: nil)
      end

      def apply_filter_char_appended(model, msg)
        model.with(filter_buffer: model.filter_buffer + msg.char)
      end

      def apply_filter_char_deleted(model)
        return model if model.filter_buffer.empty?

        model.with(filter_buffer: model.filter_buffer[0...-1])
      end

      # Commit the typed buffer as the active filter and return to grid.
      # Empty buffer commits as nil (clears any prior filter).
      #
      # Re-clamp the cursor to the first visible row of the new filter:
      # without this the prior cursor coords could point at a row the
      # filter just hid, which downstream cursor-navigation handlers
      # treat as "no current row" and refuse to move (the user is then
      # wedged with visible matches but no selectable row). Same shape
      # `apply_project_scope` uses on scope changes.
      def apply_filter_committed(model)
        committed = model.filter_buffer.empty? ? nil : model.filter_buffer
        new_model = model.with(mode: :grid, filter: committed, filter_buffer: "")
        visible = visible_snapshot(new_model)
        cursor = visible.nil? ? new_model.cursor : first_visible_cursor(visible)
        new_model.with(cursor: cursor)
      end

      # Cancel the filter prompt without committing. Preserves any
      # previously-committed filter (Esc only clears the in-progress
      # buffer; clearing a committed filter is a separate keystroke
      # in grid mode).
      def apply_filter_cancelled(model)
        model.with(mode: :grid, filter_buffer: "")
      end

      # ---- Keystroke-derived handlers (added in U10) ----

      def apply_flash(model, msg)
        model.with(flash: msg.text, flash_set_at: Time.now)
      end

      # Cursor moves one row down within the same project; on overflow,
      # advances to the first row of the next project that has visible
      # rows. Stays clamped at the last row of the last non-empty project
      # rather than wrapping — wrap would mask the grid's scroll
      # boundary.
      def apply_cursor_down(model)
        visible = visible_snapshot(model)
        return model if visible.nil? || model.cursor.nil?

        project_idx, row_idx = model.cursor
        return model unless project_idx.between?(0, visible.projects.size - 1)

        rows = visible.projects[project_idx].rows
        if row_idx + 1 < rows.size
          model.with(cursor: [ project_idx, row_idx + 1 ])
        else
          next_idx = next_non_empty_project_idx(visible, project_idx + 1)
          next_idx ? model.with(cursor: [ next_idx, 0 ]) : model
        end
      end

      def apply_cursor_up(model)
        visible = visible_snapshot(model)
        return model if visible.nil? || model.cursor.nil?

        project_idx, row_idx = model.cursor
        return model unless project_idx.between?(0, visible.projects.size - 1)

        if row_idx > 0
          model.with(cursor: [ project_idx, row_idx - 1 ])
        else
          prev_idx = prev_non_empty_project_idx(visible, project_idx - 1)
          if prev_idx
            last_row = visible.projects[prev_idx].rows.size - 1
            model.with(cursor: [ prev_idx, last_row ])
          else
            model
          end
        end
      end

      def apply_show_help(model)
        model.with(mode: :help)
      end

      # TriageState mutates in place (the loop holds a single instance
      # per triage session), so the model itself is returned unchanged.
      # No-op when triage_state is nil — defensive guard for keys that
      # arrive before BubbleModel#open_findings has set the state.
      def apply_triage_cursor_down(model)
        model.triage_state&.cursor_down
        model
      end

      def apply_triage_cursor_up(model)
        model.triage_state&.cursor_up
        model
      end

      # Pre-fill the filter buffer with the active filter so `/` followed
      # by edits feels like in-place editing (curses parity).
      def apply_open_filter_prompt(model)
        model.with(mode: :filter, filter_buffer: model.filter.to_s)
      end

      # Esc / `q` from a sub-mode returns to grid. Clears triage_state
      # and tail_state on exit so the next entry starts clean. Help
      # overlay dismisses to grid; filter mode goes through
      # FilterCancelled (still routes through Back symmetrically here
      # for the keystroke that produced this Message).
      def apply_back(model)
        case model.mode
        when :triage then model.with(mode: :grid, triage_state: nil)
        when :log_tail then model.with(mode: :grid, tail_state: nil)
        when :help, :filter then model.with(mode: :grid)
        else model
        end
      end

      # `n == 0` clears scope (all projects). Out-of-range still flips
      # the scope (Snapshot returns an empty-projects view); cursor
      # resets to the first non-empty project or nil if the scoped grid
      # is empty.
      def apply_project_scope(model, msg)
        new_model = model.with(scope: msg.n)
        visible = visible_snapshot(new_model)
        cursor = visible.nil? ? [ 0, 0 ] : first_visible_cursor(visible)
        new_model.with(cursor: cursor)
      end

      # ---- Cursor / visibility helpers ----

      def visible_snapshot(model)
        snap = model.snapshot
        return nil if snap.nil?

        snap.scope_to_project_index(model.scope).filter_by_slug(model.filter)
      end

      def next_non_empty_project_idx(visible, start_idx)
        idx = start_idx
        while idx < visible.projects.size
          return idx unless visible.projects[idx].rows.empty?

          idx += 1
        end
        nil
      end

      def prev_non_empty_project_idx(visible, start_idx)
        idx = start_idx
        while idx >= 0
          return idx unless visible.projects[idx].rows.empty?

          idx -= 1
        end
        nil
      end

      def first_visible_cursor(visible)
        first = next_non_empty_project_idx(visible, 0)
        first.nil? ? nil : [ first, 0 ]
      end
    end
  end
end
