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

      # Recurring no-op tick whose handler does nothing but yield the
      # Ruby GVL. bubbletea-ruby's `tea_input_read_raw` C call holds
      # the GVL without releasing it, which starves the StateSource
      # polling thread. Scheduling this tick at ~10ms intervals keeps
      # background threads alive — the main loop's `process_ticks`
      # gives them a Ruby checkpoint between input polls.
      # See `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`.
      YieldTick = Class.new
      YIELD_TICK = YieldTick.new.freeze

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
      # `BubbleModel#update` translates a `Bubbletea::KeyMessage` into
      # the `(mode, key, row)` triple `KeyMap.message_for` expects, then
      # routes the resulting Message either through Update.apply (pure
      # state transitions) or through BubbleModel's side-effect handlers
      # (DispatchCommand → takeover_command, OpenFindings → file I/O,
      # Bulk* / ToggleFinding → run_quiet!).

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

      # Triage `a` — bulk-accept all findings on the task currently
      # under triage. Payload-free singleton: `BubbleModel`'s handler
      # reads `triage_state` (which captures the slug + folder at the
      # moment triage was opened) instead of trusting the live grid
      # row, which a 1Hz snapshot poll could have re-pointed at a
      # different task before the keystroke landed.
      BulkAccept = Class.new
      BULK_ACCEPT = BulkAccept.new.freeze

      # Triage `r` — bulk-reject all findings on the task currently
      # under triage. Same shape as BulkAccept; see that comment for
      # the no-payload rationale.
      BulkReject = Class.new
      BULK_REJECT = BulkReject.new.freeze

      # Triage `d` — dispatch `hive develop` against the task currently
      # under triage. Payload-free for the same race-tolerance reason:
      # the handler resolves the develop argv from `triage_state`'s
      # captured folder, never the live grid row that may have drifted
      # under concurrent snapshot polls.
      TriageDevelop = Class.new
      TRIAGE_DEVELOP = TriageDevelop.new.freeze

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

      # `g` — jump to the top of the focused pane (first project on
      # left; first row of first project on right). Vim convention.
      CursorJumpTop = Class.new
      CURSOR_JUMP_TOP = CursorJumpTop.new.freeze

      # `G` — jump to the bottom of the focused pane (last project on
      # left; last row of last non-empty project on right).
      CursorJumpBottom = Class.new
      CURSOR_JUMP_BOTTOM = CursorJumpBottom.new.freeze

      # Triage-mode `j` / KEY_DOWN. Distinct from grid-mode `CursorDown`
      # so Update can route to `TriageState#cursor_down` instead of
      # mutating `model.cursor` (which is the grid coord).
      TriageCursorDown = Class.new
      TRIAGE_CURSOR_DOWN = TriageCursorDown.new.freeze

      # Triage-mode `k` / KEY_UP.
      TriageCursorUp = Class.new
      TRIAGE_CURSOR_UP = TriageCursorUp.new.freeze

      # ---- Pane focus messages (v2 two-pane layout) ----

      # Tab / Shift+Tab — toggle pane focus between :left and :right.
      PaneFocusToggled = Class.new
      PANE_FOCUS_TOGGLED = PaneFocusToggled.new.freeze

      # `h` / `l` — explicit pane focus shift. `target` is :left | :right.
      PaneFocusChanged = Data.define(:target)

      # ---- New-idea prompt messages (consumed in :new_idea mode) ----
      # Mirror the FilterChar* shape so Update can be unit-tested against
      # the full message set without dependency on view code.

      # `n` from :grid — open the inline new-idea prompt (mode → :new_idea).
      OpenNewIdeaPrompt = Class.new
      OPEN_NEW_IDEA_PROMPT = OpenNewIdeaPrompt.new.freeze

      # User typed a printable character into the new-idea buffer.
      NewIdeaCharAppended = Data.define(:char)

      # User pressed Backspace in the new-idea prompt.
      NewIdeaCharDeleted = Class.new
      NEW_IDEA_CHAR_DELETED = NewIdeaCharDeleted.new.freeze

      # User pressed Enter in the new-idea prompt — submit the buffer
      # as a new `hive new <project> "<title>"` invocation. The project
      # is resolved by the handler from `model.scope`.
      NewIdeaSubmitted = Class.new
      NEW_IDEA_SUBMITTED = NewIdeaSubmitted.new.freeze

      # User pressed Esc — clear the buffer and return to :grid mode.
      NewIdeaCancelled = Class.new
      NEW_IDEA_CANCELLED = NewIdeaCancelled.new.freeze

      # Recurring tick that drains new bytes from the active log_tail.
      # `Tail#poll!` is only meaningful while the user is in :log_tail
      # mode; the handler reschedules a fresh tick if mode is still
      # :log_tail and stops the cycle otherwise. Without this, the view
      # was frozen at the bytes read by `Tail#open!`.
      LogTailPoll = Class.new
      LOG_TAIL_POLL = LogTailPoll.new.freeze

      # No-op — explicit "do nothing" so case statements can match
      # without resorting to nil. Returned for unbound keystrokes.
      Noop = Class.new
      NOOP = Noop.new.freeze
    end
  end
end
