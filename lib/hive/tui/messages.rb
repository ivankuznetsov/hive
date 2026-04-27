require "hive"

module Hive
  module Tui
    # Closed enum of Message types the Update function dispatches on.
    # Bubble Tea's runner emits framework messages (KeyMessage,
    # WindowSizeMessage, ResumeMessage, etc.) which Update translates
    # into these app-level Messages before applying state transitions.
    #
    # Each Message is a frozen Data record. The shape is:
    #   - one Message per state-transition kind
    #   - fields carry exactly the data Update needs to apply the transition
    #   - no behavior on the records themselves — pure data
    #
    # Adding a new Message: define it here, add an `Update.apply` branch
    # for it, write the test case in `test/unit/tui/update_test.rb`.
    module Messages
      # Translated from Bubbletea::KeyMessage. `key` is either a single-
      # character String for printable input, or a `:key_*` Symbol for
      # special keys (`:key_enter`, `:key_escape`, `:key_up`, etc.) —
      # same surface `Hive::Tui::KeyMap` already accepts.
      KeyPressed = Data.define(:key)

      # The 1Hz background poll completed successfully and produced a
      # new Snapshot. Update replaces `model.snapshot` and clears
      # `last_error`.
      SnapshotArrived = Data.define(:snapshot)

      # The 1Hz background poll raised. Update keeps the previous
      # snapshot (so the user keeps seeing data) and writes `last_error`
      # so the renderer can flag staleness.
      PollFailed = Data.define(:error)

      # Translated from Bubbletea::WindowSizeMessage. Update writes
      # `cols`/`rows` so view layout decisions can read them.
      WindowSized = Data.define(:cols, :rows)

      # Sent by the takeover callable after a workflow-verb subprocess
      # exits. `verb` is the second argv element (e.g., "pr",
      # "develop") supplied by the dispatcher at Message construction
      # time — Update doesn't re-derive it. `exit_code` carries the
      # POSIX-shell-convention status (0 success; 128+signo for signal
      # kills; 127 command-not-found).
      SubprocessExited = Data.define(:verb, :exit_code)

      # Cooperative shutdown signal — set by the SIGHUP trap (via
      # `runner.send`) and by `q`-keystroke dispatch in grid mode.
      # Update returns `Bubbletea.quit` so the runner exits cleanly.
      TerminateRequested = Class.new
      TERMINATE_REQUESTED = TerminateRequested.new.freeze

      # Periodic tick used to age out flash messages. Fires once per
      # second; Update inspects `flash_set_at` and clears the flash if
      # older than the TTL.
      Tick = Class.new
      TICK = Tick.new.freeze

      # ---- Filter-prompt messages (consumed in :filter mode) ----
      # Defined in U4 (not U9 where the FilterPrompt view lives) so the
      # message contract is centralized and Update can be unit-tested
      # against the full message set without dependency on view code.

      # User typed a printable character into the filter buffer. Char
      # is a single-character String.
      FilterCharAppended = Data.define(:char)

      # User pressed Backspace in the filter prompt.
      FilterCharDeleted = Class.new
      FILTER_CHAR_DELETED = FilterCharDeleted.new.freeze

      # User pressed Enter in the filter prompt — commits the typed
      # buffer as the active filter and returns to grid mode.
      FilterCommitted = Class.new
      FILTER_COMMITTED = FilterCommitted.new.freeze

      # User pressed Esc in the filter prompt — clears the buffer
      # (and any previously-committed filter) and returns to grid mode.
      FilterCancelled = Class.new
      FILTER_CANCELLED = FilterCancelled.new.freeze

      # ---- Keystroke-derived messages (returned by KeyMap.message_for) ----
      # Added in U5 alongside the KeyMap reshape. Each maps 1:1 to a
      # legacy `KeyMap.dispatch` `[verb, payload]` tuple shape so the
      # back-compat shim can translate either direction during the
      # migration window.

      # Dispatch a workflow verb subprocess. `argv` is the full command
      # array (`["hive", "plan", "slug", "--from", "2-brainstorm"]`),
      # `verb` is `argv[1]` cached at construction time so the renderer
      # can flash exit codes by verb name without re-deriving.
      DispatchCommand = Data.define(:argv, :verb)

      # Status-line flash. `text` is the literal message; renderer
      # decides styling.
      Flash = Data.define(:text)

      # Enter on a `review_findings` row — push triage mode for `row`.
      OpenFindings = Data.define(:row)

      # Enter on an `agent_running` row — push log-tail mode for `row`.
      OpenLogTail = Data.define(:row)

      # Triage Space — toggle accept/reject on the current finding.
      # `row` is the parent task row from grid mode, used by the
      # triage subloop to derive slug + finding context.
      ToggleFinding = Data.define(:row)

      # Triage `a` — bulk-accept all findings on the row's task.
      BulkAccept = Data.define(:slug)

      # Triage `r` — bulk-reject all findings on the row's task.
      BulkReject = Data.define(:slug)

      # `1`–`9` scope to the Nth registered project; `0` clears scope.
      ProjectScope = Data.define(:n)

      # `?` — toggle help overlay.
      ShowHelp = Class.new
      SHOW_HELP = ShowHelp.new.freeze

      # `/` — open filter prompt (mode → :filter).
      OpenFilterPrompt = Class.new
      OPEN_FILTER_PROMPT = OpenFilterPrompt.new.freeze

      # Esc / `q` from a sub-mode — return to grid.
      Back = Class.new
      BACK = Back.new.freeze

      # `j` / KEY_DOWN.
      CursorDown = Class.new
      CURSOR_DOWN = CursorDown.new.freeze

      # `k` / KEY_UP.
      CursorUp = Class.new
      CURSOR_UP = CursorUp.new.freeze

      # No-op — explicit "do nothing" so case statements can match
      # without resorting to nil. Returned for unbound keystrokes.
      Noop = Class.new
      NOOP = Noop.new.freeze
    end
  end
end
