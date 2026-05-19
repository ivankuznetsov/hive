require "hive"
require "hive/tui/model"

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
    #   - no runtime behavior beyond narrow constructor validation
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
      #
      # `folder` is optional — present only when the dispatcher wrapped
      # @dispatch to thread per-row context through the reaper Thread
      # (today: `refresh_red_status_diagnosis`, so the diagnose-subprocess
      # exit handler can evict the right slot from @diagnosis_inflight).
      # Default nil keeps every existing call site (workflow-verb spawns,
      # takeover-command spawns) unchanged.
      SubprocessExited = Data.define(:verb, :exit_code, :folder) do
        def initialize(verb:, exit_code:, folder: nil)
          super
        end
      end

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

      # Raw text bytes decoded before mode-specific routing. BubbleModel
      # translates this by current mode so paste in grid mode cannot
      # mutate hidden prompt buffers.
      RawTextInput = Data.define(:text, :paste)

      # ---- Filter-prompt messages (consumed in :filter mode) ----
      # Defined in U4 (not U9 where the FilterPrompt view lives) so the
      # message contract is centralized and Update can be unit-tested
      # against the full message set without dependency on view code.

      # User typed a printable character into the filter buffer. Char
      # is a single-character String.
      FilterCharAppended = Data.define(:char)

      # User pasted or otherwise entered multiple text characters into
      # the filter prompt. Kept separate from FilterCharAppended so the
      # decoder can batch terminal chunks without losing filter support.
      FilterTextInserted = Data.define(:text)

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

      # Enter on a `recover_review` row. REVIEW_ERROR / REVIEW_CI_STALE
      # clear the observed marker and re-run. REVIEW_STALE does the same
      # only for incomplete triage artifacts; completed stale passes
      # report the manual pass-cleanup step (or open the focal escalations
      # file in browse mode) and leave the marker intact.
      #
      # `force: true` is set by the `r` verb-key path in key_map.rb. It
      # is the operator's explicit "I edited the file, retry now"
      # gesture and bypasses BubbleModel#recover_review's
      # `retryable_review_stale?` gate so max_passes-hit REVIEW_STALE
      # rows are re-runnable from the TUI. The default `force: false`
      # preserves Enter's existing browse-not-retry behavior.
      RecoverReview = Data.define(:row, :force) do
        def initialize(row:, force: false)
          super
        end
      end

      # Enter on an `error` row whose marker is a non-kill-class ERROR.
      # Kill-class signal kills (130/137/143) are auto-healed elsewhere;
      # this message handles real failures (exit_code=1 etc.) the
      # auto-healer deliberately leaves alone. The handler clears the
      # ERROR marker via `hive markers clear --name ERROR --match-attr
      # exit_code=N` and re-runs the task with `hive run <folder>` if
      # the clear succeeds. Mirrors RecoverReview so the user keeps a
      # uniform "Enter to retry" gesture across recoverable failures.
      RecoverError = Data.define(:row)

      # Enter on a gated red row — open the diagnosis/action view
      # without clearing markers or dispatching recovery.
      OpenRedStatusDetail = Data.define(:row)

      # Enter inside the red-status detail view — run the same
      # recovery handler the grid row used to run directly.
      RedStatusAutofix = Data.define(:row)

      # `f` inside the red-status detail view — open the task worktree
      # in $EDITOR for manual edits. This never clears markers.
      OpenManualFix = Data.define(:row)

      # `R` inside the red-status detail view — ask Hive to refresh the
      # durable headless diagnosis artifact for this row.
      RefreshRedStatusDiagnosis = Data.define(:row)

      # Enter on a `needs_input` row — suspend the TUI and open the
      # row's input target in the user's editor so they can answer or
      # revise inline questions before re-running the stage.
      OpenInputEditor = Data.define(:row)

      # `o` in grid mode — suspend the TUI and open the focused row's
      # hive-state task folder in the user's editor for read-only
      # browsing. Pure browse gesture: no marker mutation, no workflow
      # verb dispatch, no auto-continue. Distinct from `Enter`
      # (workflow-contextual) and the verb keys (subprocess dispatch).
      OpenTaskFolder = Data.define(:row)

      # Enter on a completed 7-finalize row — browse the final summary
      # document in $EDITOR. Falls back to pr.md if summary.md is missing.
      OpenSummary = Data.define(:row)

      # Sent by the editor takeover callable after the editor exits.
      # `changed` is true when the input target's mtime changed during
      # the edit window, so the status flash can distinguish a saved
      # edit from a no-op/cancel.
      InputEditorExited = Data.define(:slug, :exit_code, :changed)

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

      # `n` from :grid — open the inline new-idea prompt, or a project
      # picker first when scope is ★ All projects.
      OpenNewIdeaPrompt = Class.new
      OPEN_NEW_IDEA_PROMPT = OpenNewIdeaPrompt.new.freeze

      # Project picker cursor movement for the pre-new-idea selection
      # shown when the operator starts from ★ All projects.
      NewIdeaProjectCursorDown = Class.new
      NEW_IDEA_PROJECT_CURSOR_DOWN = NewIdeaProjectCursorDown.new.freeze

      NewIdeaProjectCursorUp = Class.new
      NEW_IDEA_PROJECT_CURSOR_UP = NewIdeaProjectCursorUp.new.freeze

      # Enter in the project picker — lock the highlighted project as
      # the target and continue into the normal new-idea prompt.
      NewIdeaProjectSelected = Class.new
      NEW_IDEA_PROJECT_SELECTED = NewIdeaProjectSelected.new.freeze

      # User inserted text into the new-idea buffer at the cursor. This
      # is the primary path for both printable characters and paste.
      # (Note: `NewIdeaCharAppended` was an earlier separate-character
      # path; KeyMap only emits TextInserted now, so the Char variant
      # was removed in PR #25.)
      NewIdeaTextInserted = Data.define(:text)

      # Bracketed paste landed in :new_idea mode. BubbleModel's
      # `handle_new_idea_paste` handles the clipboard/file probe and
      # staging side effects before Update sees a NewIdeaImageAttached
      # or NewIdeaTextInserted fallback. The side-effect handler can
      # also return [model, nil] WITHOUT producing a downstream
      # message — that path covers oversize-image flash, drag-drop-
      # ignored flash, the missing-clipboard-tool hint, and the
      # rescue branch for paste failures.
      NewIdeaPasteRequested = Data.define(:raw_text)

      # An image was staged for the in-progress composer. Update inserts
      # the textual placeholder and appends the exact attachment record
      # produced by the side-effecting staging path.
      NewIdeaImageAttached = Data.define(:attachment) do
        def initialize(attachment:)
          unless attachment.is_a?(Hive::Tui::Model::Attachment)
            raise ArgumentError, "attachment must be Hive::Tui::Model::Attachment"
          end

          super(attachment: attachment)
        end
      end

      # Cursor navigation within the new-idea prompt.
      NewIdeaCursorLeft = Class.new
      NEW_IDEA_CURSOR_LEFT = NewIdeaCursorLeft.new.freeze

      NewIdeaCursorRight = Class.new
      NEW_IDEA_CURSOR_RIGHT = NewIdeaCursorRight.new.freeze

      NewIdeaCursorHome = Class.new
      NEW_IDEA_CURSOR_HOME = NewIdeaCursorHome.new.freeze

      NewIdeaCursorEnd = Class.new
      NEW_IDEA_CURSOR_END = NewIdeaCursorEnd.new.freeze

      # User pressed Backspace in the new-idea prompt (delete backward).
      NewIdeaCharDeleted = Class.new
      NEW_IDEA_CHAR_DELETED = NewIdeaCharDeleted.new.freeze

      # User pressed Delete in the new-idea prompt (delete forward).
      NewIdeaCharDeletedForward = Class.new
      NEW_IDEA_CHAR_DELETED_FORWARD = NewIdeaCharDeletedForward.new.freeze

      # User pressed Enter in the new-idea prompt — submit the buffer
      # as a new `hive new <project> "<title>"` invocation. The project
      # is resolved by the handler from `model.scope`.
      NewIdeaSubmitted = Class.new
      NEW_IDEA_SUBMITTED = NewIdeaSubmitted.new.freeze

      # User pressed Esc — clear the buffer and return to :grid mode.
      NewIdeaCancelled = Class.new
      NEW_IDEA_CANCELLED = NewIdeaCancelled.new.freeze

      # `X` in grid mode — drop the currently scoped project from the
      # global registry, gated to entries whose `error ==
      # "missing_project_path"`. Payload-free singleton: BubbleModel's
      # handler resolves the target by `model.scope` against
      # `snapshot.projects` rather than trusting a stale row, and flashes
      # a refusal when the gate fails (no project selected, scope == ★
      # All, or the project is healthy and shouldn't be silently
      # deregistered).
      DropScopedProjectIfMissing = Class.new
      DROP_SCOPED_PROJECT_IF_MISSING = DropScopedProjectIfMissing.new.freeze

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
