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
        when Messages::FilterTextInserted
          [ apply_filter_text_inserted(model, message), nil ]
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
        when Messages::CursorJumpTop
          [ apply_cursor_jump_top(model), nil ]
        when Messages::CursorJumpBottom
          [ apply_cursor_jump_bottom(model), nil ]
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
        when Messages::PaneFocusToggled
          [ apply_pane_focus_toggled(model), nil ]
        when Messages::PaneFocusChanged
          [ apply_pane_focus_changed(model, message), nil ]
        when Messages::OpenNewIdeaPrompt
          [ apply_open_new_idea_prompt(model), nil ]
        when Messages::NewIdeaCharAppended
          [ apply_new_idea_char_appended(model, message), nil ]
        when Messages::NewIdeaTextInserted
          [ apply_new_idea_text_inserted(model, message), nil ]
        when Messages::NewIdeaCursorLeft
          [ apply_new_idea_cursor_left(model), nil ]
        when Messages::NewIdeaCursorRight
          [ apply_new_idea_cursor_right(model), nil ]
        when Messages::NewIdeaCursorHome
          [ apply_new_idea_cursor_home(model), nil ]
        when Messages::NewIdeaCursorEnd
          [ apply_new_idea_cursor_end(model), nil ]
        when Messages::NewIdeaCharDeleted
          [ apply_new_idea_char_deleted(model), nil ]
        when Messages::NewIdeaCharDeletedForward
          [ apply_new_idea_char_deleted_forward(model), nil ]
        when Messages::NewIdeaCancelled
          [ apply_new_idea_cancelled(model), nil ]
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

      def apply_filter_text_inserted(model, msg)
        model.with(filter_buffer: model.filter_buffer + msg.text.to_s)
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

      # j / KEY_DOWN. Routes by `pane_focus`:
      #   :left  → advance the projects-pane selection (model.scope).
      #   :right → advance the task cursor (existing v1 behaviour: row,
      #            then next project's first row, clamped at the last
      #            row of the last non-empty project).
      def apply_cursor_down(model)
        return apply_left_pane_cursor_down(model) if model.pane_focus == :left

        apply_right_pane_cursor_down(model)
      end

      def apply_cursor_up(model)
        return apply_left_pane_cursor_up(model) if model.pane_focus == :left

        apply_right_pane_cursor_up(model)
      end

      # Left-pane navigation drives `model.scope`. Scope 0 = ★ All projects;
      # 1..projects.size = the Nth registered project. Clamped at both
      # ends (no wrap — same boundary contract as the right pane).
      # ProjectScope's snapshot/cursor recompute is reused via
      # `apply_project_scope` so the right pane stays coherent with
      # the new scope.
      def apply_left_pane_cursor_down(model)
        snap = model.snapshot
        max_scope = snap ? snap.projects.size : 0
        return model if model.scope >= max_scope

        apply_project_scope(model, Messages::ProjectScope.new(n: model.scope + 1))
      end

      def apply_left_pane_cursor_up(model)
        return model if model.scope <= 0

        apply_project_scope(model, Messages::ProjectScope.new(n: model.scope - 1))
      end

      def apply_right_pane_cursor_down(model)
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

      def apply_right_pane_cursor_up(model)
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

      # When the project pane is suppressed (cols < Model::TWO_PANE_MIN_COLS),
      # focus has nowhere to go on the left — the visible task table
      # would lose its highlight and j/k would mutate hidden project
      # scope. Force right focus in that regime; it's the only visible
      # surface anyway. Threshold lives on Model so render layer
      # (BubbleModel#compose_two_pane_view) and focus layer here cannot
      # drift out of sync.

      # `g` jumps to the top of the focused pane. Left pane → scope=0
      # (★ All projects); right pane → cursor=[first_visible_project, 0].
      def apply_cursor_jump_top(model)
        if model.pane_focus == :left
          model.with(scope: 0)
        else
          visible = visible_snapshot(model)
          return model if visible.nil?

          first_idx = next_non_empty_project_idx(visible, 0)
          first_idx ? model.with(cursor: [ first_idx, 0 ]) : model
        end
      end

      # `G` jumps to the bottom of the focused pane. Left pane →
      # scope=projects.size (last registered project); right pane →
      # cursor=[last_visible_project, last_row].
      def apply_cursor_jump_bottom(model)
        if model.pane_focus == :left
          snap = model.snapshot
          return model if snap.nil?

          model.with(scope: snap.projects.size)
        else
          visible = visible_snapshot(model)
          return model if visible.nil?

          last_idx = prev_non_empty_project_idx(visible, visible.projects.size - 1)
          return model if last_idx.nil?

          last_row = visible.projects[last_idx].rows.size - 1
          model.with(cursor: [ last_idx, last_row ])
        end
      end

      def apply_pane_focus_toggled(model)
        return model.with(pane_focus: :right) if model.cols.to_i < Model::TWO_PANE_MIN_COLS

        target = model.pane_focus == :left ? :right : :left
        model.with(pane_focus: target)
      end

      def apply_pane_focus_changed(model, msg)
        return model unless %i[left right].include?(msg.target)
        # Reject :left transitions when the project pane is suppressed —
        # h/Tab in single-pane mode is a no-op rather than a stuck focus
        # on a hidden pane.
        return model.with(pane_focus: :right) if msg.target == :left && model.cols.to_i < Model::TWO_PANE_MIN_COLS

        model.with(pane_focus: msg.target)
      end

      # ---- New-idea prompt handlers (U6) ----
      #
      # Submit (`Messages::NewIdeaSubmitted`) is intentionally NOT
      # handled here — it requires a subprocess call (`hive new …`)
      # which lives in BubbleModel#handle_side_effect. That preserves
      # Update's purity (no I/O, no Bubbletea coupling). On submit the
      # BubbleModel reads `model.new_idea_buffer`, dispatches the child,
      # and resets the model via `apply_new_idea_cancelled`-equivalent
      # transition (mode → :grid, buffer cleared) on either success or
      # validation failure.

      def apply_open_new_idea_prompt(model)
        model.with(mode: :new_idea, new_idea_buffer: "", new_idea_cursor: 0)
      end

      def apply_new_idea_char_appended(model, msg)
        insert_new_idea_text(model, msg.char.to_s)
      end

      def apply_new_idea_text_inserted(model, msg)
        insert_new_idea_text(model, msg.text.to_s)
      end

      def apply_new_idea_cursor_left(model)
        buffer, cursor = normalized_new_idea_buffer_and_cursor(model)
        model.with(new_idea_buffer: buffer, new_idea_cursor: [ cursor - 1, 0 ].max)
      end

      def apply_new_idea_cursor_right(model)
        buffer, cursor = normalized_new_idea_buffer_and_cursor(model)
        model.with(new_idea_buffer: buffer, new_idea_cursor: [ cursor + 1, buffer.length ].min)
      end

      def apply_new_idea_cursor_home(model)
        buffer, = normalized_new_idea_buffer_and_cursor(model)
        model.with(new_idea_buffer: buffer, new_idea_cursor: 0)
      end

      def apply_new_idea_cursor_end(model)
        buffer, = normalized_new_idea_buffer_and_cursor(model)
        model.with(new_idea_buffer: buffer, new_idea_cursor: buffer.length)
      end

      def apply_new_idea_char_deleted(model)
        buffer, cursor = normalized_new_idea_buffer_and_cursor(model)
        return model.with(new_idea_buffer: buffer, new_idea_cursor: cursor) if cursor.zero?

        prefix = buffer[0...(cursor - 1)].to_s
        suffix = buffer[cursor..].to_s
        model.with(new_idea_buffer: prefix + suffix, new_idea_cursor: cursor - 1)
      end

      def apply_new_idea_char_deleted_forward(model)
        buffer, cursor = normalized_new_idea_buffer_and_cursor(model)
        return model.with(new_idea_buffer: buffer, new_idea_cursor: cursor) if cursor >= buffer.length

        prefix = buffer[0...cursor].to_s
        suffix = buffer[(cursor + 1)..].to_s
        model.with(new_idea_buffer: prefix + suffix, new_idea_cursor: cursor)
      end

      def apply_new_idea_cancelled(model)
        model.with(mode: :grid, new_idea_buffer: "", new_idea_cursor: 0)
      end

      def insert_new_idea_text(model, raw_text)
        text = normalize_new_idea_text(raw_text)
        return clamp_new_idea_cursor(model) if text.empty?

        buffer, cursor = normalized_new_idea_buffer_and_cursor(model)
        if buffer.length + text.length > Model::NEW_IDEA_BUFFER_MAX_CHARS
          return model.with(
            new_idea_buffer: buffer,
            new_idea_cursor: cursor,
            flash: "title too long",
            flash_set_at: Time.now
          )
        end

        prefix = buffer[0...cursor].to_s
        suffix = buffer[cursor..].to_s
        model.with(
          new_idea_buffer: prefix + text + suffix,
          new_idea_cursor: cursor + text.length
        )
      end

      def clamp_new_idea_cursor(model)
        buffer, cursor = normalized_new_idea_buffer_and_cursor(model)
        model.with(new_idea_buffer: buffer, new_idea_cursor: cursor)
      end

      def normalized_new_idea_buffer_and_cursor(model)
        buffer = model.new_idea_buffer.to_s
        cursor = model.new_idea_cursor.to_i.clamp(0, buffer.length)
        [ buffer, cursor ]
      end

      def normalize_new_idea_text(text)
        text.to_s
            .delete_prefix("\e[200~")
            .delete_suffix("\e[201~")
            .gsub(/[\r\n\t]+/, " ")
            .gsub(/ {2,}/, " ")
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
