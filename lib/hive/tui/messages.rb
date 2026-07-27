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

      # Sent by a workflow-verb subprocess reaper after the child exits.
      # `verb` is the second argv element (e.g., "pr", "develop")
      # supplied by the dispatcher at Message construction time — Update
      # doesn't re-derive it. `exit_code` carries the POSIX-shell-
      # convention status (0 success; 128+signo for signal kills; 127
      # command-not-found). `spawn_id` is the optional 8-char correlation
      # id used to read the exact per-spawn capture for diagnosis; nil
      # keeps legacy/manual message construction working.
      SubprocessExited = Data.define(:verb, :exit_code, :spawn_id) do
        def initialize(verb:, exit_code:, spawn_id: nil)
          super(verb: verb, exit_code: exit_code, spawn_id: spawn_id)
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
      # (DispatchCommand → takeover_command, OpenLogTail / OpenInputEditor
      # → file I/O).

      # Dispatch a workflow verb subprocess. `argv` is the full command
      # array (`["hive", "plan", "slug", "--from", "2-brainstorm"]`), # not-a-stage-ref: command-shape documentation example
      # `verb` is `argv[1]` cached at construction time so the renderer
      # can flash exit codes by verb name without re-deriving.
      DispatchCommand = Data.define(:argv, :verb)

      # Status-line flash. `text` is the literal message; renderer
      # decides styling.
      Flash = Data.define(:text)

      # Enter on an `agent_running` row — push log-tail mode for `row`.
      OpenLogTail = Data.define(:row)

      # Enter on a `recover_review` row. REVIEW_ERROR / REVIEW_CI_STALE
      # submit the observed marker to the coordinator. REVIEW_STALE does
      # the same only for incomplete triage artifacts; completed stale passes
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

      # Enter on an `error` row. The handler submits the observed marker
      # to the shared recovery coordinator, which owns comparison,
      # durable admission, marker transition, and dispatch.
      RecoverError = Data.define(:row)

      # Enter on a gated red row — open the diagnosis/action view
      # without clearing markers or dispatching recovery. `agent_label`
      # is the resolved development-agent name, resolved by BubbleModel
      # before dispatch so the no-I/O Update layer never reads disk.
      OpenRedStatusDetail = Data.define(:row, :agent_label) do
        def initialize(row:, agent_label: nil)
          super
        end
      end

      # `I` in grid mode — open the read-only four-stage implementation
      # ownership/provenance table carried by the status snapshot.
      OpenImplementationIdentityDetail = Data.define(:row)

      # Enter inside the red-status detail view — run the same
      # recovery handler the grid row used to run directly.
      RedStatusAutofix = Data.define(:row)

      # Scroll the captured red-status detail log snapshot. `direction`
      # is :up (older lines) or :down (newer lines); `amount` is a line
      # count and is clamped by Update against the rendered capacity.
      RedStatusDetailScroll = Data.define(:direction, :amount)

      # Scroll the help overlay's wrapped content viewport. `direction`
      # is :up or :down; `amount` is a line count and is clamped by
      # Update against `Views::HelpOverlay.max_scroll_offset`.
      HelpScroll = Data.define(:direction, :amount)
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

      # `i` in grid mode — read the focused row's source idea.md and
      # show its original_text in the bottom strip. Carries the row so
      # BubbleModel's side-effect handler can resolve `row.folder` at
      # the moment of the keystroke; this cannot be a payload-free
      # singleton because snapshot polling may move the live cursor.
      OpenIdeaPreview = Data.define(:row)

      # `s` in grid mode — suspend the TUI and open the focused row's
      # configured development agent in the feature worktree. BubbleModel
      # owns the marker flip and the foreground takeover here; the
      # follow-up `AgentSteerExited` message (dispatched by the takeover
      # callable after the agent process exits) is what owns the
      # archive-on-exit side effect.
      OpenInAgent = Data.define(:row)

      # `T` in grid mode — open the full-screen token usage matrix.
      OpenTokenStats = Class.new
      OPEN_TOKEN_STATS = OpenTokenStats.new.freeze

      # q / Esc in token-stats mode — return to the grid.
      CloseTokenStats = Class.new
      CLOSE_TOKEN_STATS = CloseTokenStats.new.freeze

      # `z` in grid mode — open the full-screen archive pane.
      OpenArchivePane = Class.new
      OPEN_ARCHIVE_PANE = OpenArchivePane.new.freeze

      # q / Esc in archive mode — return to the grid.
      CloseArchivePane = Class.new
      CLOSE_ARCHIVE_PANE = CloseArchivePane.new.freeze

      # Left/right arrows in token-stats mode. direction is :in or :out.
      TokenStatsScopeChanged = Data.define(:direction)

      # Up/down arrows in token-stats mode. direction is :next or :previous.
      TokenStatsSelectionMoved = Data.define(:direction)

      # Enter on a completed finalize-stage row — browse the final summary
      # document in $EDITOR. Falls back to pr.md if summary.md is missing.
      OpenSummary = Data.define(:row)

      # Sent by the editor takeover callable after the editor exits.
      # `changed` is true when the input target's mtime changed during
      # the edit window, so the status flash can distinguish a saved
      # edit from a no-op/cancel.
      InputEditorExited = Data.define(:slug, :exit_code, :changed)

      # Sent by the manual-steering agent takeover callable after the
      # interactive agent exits. BubbleModel uses this follow-up to move
      # the task folder out of the active stage tree.
      AgentSteerExited = Data.define(:slug, :folder, :exit_code, :worktree)

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

      # `X` in grid mode — hard-drop the focused task. BubbleModel
      # consumes this message and constructs a `DispatchCommand` for
      # `hive drop`, so the shared CLI implementation handles
      # process/worktree/branch cleanup off the TUI thread.
      DropFocusedTask = Data.define(:row)

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
