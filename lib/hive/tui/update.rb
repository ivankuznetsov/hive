require "hive"
require "hive/tui/model"
require "hive/tui/messages"

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
        when Messages::KeyPressed
          # Stub — wired in U5 once KeyMap returns Messages.
          [ model, nil ]
        else
          # Unknown messages flow through unchanged. Future-compat with
          # framework messages we don't yet care about (FocusMessage,
          # BlurMessage, MouseMessage if mouse ever gets enabled).
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
      # stalled banner stops showing.
      def apply_snapshot_arrived(model, msg)
        model.with(snapshot: msg.snapshot, last_error: nil)
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
          flash: "`#{msg.verb}` exited #{msg.exit_code}",
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
      def apply_filter_committed(model)
        committed = model.filter_buffer.empty? ? nil : model.filter_buffer
        model.with(mode: :grid, filter: committed, filter_buffer: "")
      end

      # Cancel the filter prompt without committing. Preserves any
      # previously-committed filter (Esc only clears the in-progress
      # buffer; clearing a committed filter is a separate keystroke
      # in grid mode).
      def apply_filter_cancelled(model)
        model.with(mode: :grid, filter_buffer: "")
      end
    end
  end
end
