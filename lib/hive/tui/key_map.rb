require "shellwords"
require "hive/markers"
require "hive/tui/snapshot"
require "hive/tui/messages"

module Hive
  module Tui
    # Pure-data keystroke → Message mapper. `BubbleModel#translate_key`
    # converts a `Bubbletea::KeyMessage` to a single-character String
    # or `:key_*` Symbol and calls `message_for(mode:, key:, row:)`.
    # The result is one of `Hive::Tui::Messages::*`, ready for
    # `Update.apply` (or for `BubbleModel`'s side-effect handlers
    # when the message has external dependencies).
    #
    # The same `key` may bind to different actions across modes:
    # `a` is `archive` verb dispatch in `:grid` mode and `bulk_accept`
    # in `:triage` mode; that's why `mode:` is a required keyword. The
    # argv carried by grid-mode `Messages::DispatchCommand` comes from
    # `Hive::Tui::Snapshot::Row#suggested_command`, never synthesized
    # here — TaskAction already produced the correct `--from <stage>` /
    # `--project <name>` flags upstream.
    module KeyMap
      module_function

      # @api private
      # Hand-written grid-mode key->verb map; static UI choice rather
      # than something derivable from `Hive::Workflows::VERBS`. Capital
      # `P` opens the PR; `F` finalizes it after review.
      VERB_KEYS = {
        "b" => "brainstorm",
        "p" => "plan",
        "d" => "develop",
        "P" => "open-pr",
        "r" => "review",
        "F" => "finalize",
        "a" => "archive"
      }.freeze

      # @api private
      ENTER_KEYS = [ :key_enter, "\r", "\n" ].freeze
      # @api private
      ESCAPE_KEYS = [ :key_escape, "\e" ].freeze
      # @api private
      DOWN_KEYS = [ :key_down, "j" ].freeze
      # @api private
      UP_KEYS = [ :key_up, "k" ].freeze

      # @api private
      # Row action_keys with no `suggested_command`, mapped to the
      # contextual flash message Enter (and verb keys) should surface.
      # `error` is intentionally absent — Enter on an error-state row
      # is routed by `error_message` (clear the ERROR marker + re-run
      # for non-kill-class failures; OpenLogTail while a kill-class
      # auto-heal is in flight). The dual routing lives in the
      # `enter_message` -> `error_message` branch below.
      ENTER_FLASH_MESSAGES = {
        "archived" => "task is archived; no further action",
        "recover_execute" => "task needs recovery — open findings to re-prioritise"
      }.freeze

      # @api private
      # The TUI's auto-healer in `BubbleModel#auto_heal_kill_class_errors`
      # already clears these markers in the background, so an
      # Enter-driven recovery would race the auto-heal. KeyMap routes
      # those rows to OpenLogTail instead so the user can read the kill
      # context until the auto-heal lands. The exact code list lives on
      # `Hive::Markers::KILL_CLASS_EXIT_CODES` so this routing predicate
      # and the auto-healer never drift.
      KILL_CLASS_EXIT_CODES = Hive::Markers::KILL_CLASS_EXIT_CODES

      # @api public
      # `pane_focus:` is the v2 two-pane layout's focus indicator. v1
      # behaviour is preserved for callers that don't pass it (defaults
      # to :right, matching v1's single-pane interaction surface). Under
      # `:left` focus, j/k still emit `CURSOR_DOWN` / `CURSOR_UP`; the
      # routing-by-focus is in `Update.apply_cursor_*`. Enter on the
      # left pane jumps focus to the right (handled here so the dispatch
      # machinery in Update doesn't need a focus-aware branch).
      def message_for(mode:, key:, row:, pane_focus: :right)
        case mode
        when :grid then grid_message(key: key, row: row, pane_focus: pane_focus)
        when :triage then triage_message(key: key, row: row)
        when :log_tail then log_tail_message(key: key, row: row)
        when :red_status_detail then red_status_detail_message(key: key, row: row)
        when :filter then filter_message(key: key, row: row)
        when :help then help_message(key: key, row: row)
        when :new_idea_project then new_idea_project_message(key: key, row: row)
        when :new_idea then new_idea_message(key: key, row: row)
        else raise ArgumentError, "unknown mode: #{mode.inspect}"
        end
      end

      def grid_message(key:, row:, pane_focus: :right)
        # Pane-focus navigation runs first — it doesn't need a row.
        return Messages::PANE_FOCUS_TOGGLED if key == :key_tab || key == :key_backtab
        return Messages::PaneFocusChanged.new(target: :left) if key == "h" || key == :key_left
        return Messages::PaneFocusChanged.new(target: :right) if key == "l" || key == :key_right

        global = global_grid_message(key)
        return global if global

        # Cursor navigation works regardless of focus — Update routes
        # j/k/g/G by `model.pane_focus` (left → scope, right → row).
        return Messages::CURSOR_DOWN if DOWN_KEYS.include?(key)
        return Messages::CURSOR_UP if UP_KEYS.include?(key)
        return Messages::CURSOR_JUMP_TOP if key == "g"
        return Messages::CURSOR_JUMP_BOTTOM if key == "G"

        # Enter from the left pane jumps focus to the right pane,
        # regardless of what's under the cursor. This way the operator
        # selects a project on the left, presses Enter, and immediately
        # has the task table focused for verb dispatch.
        if pane_focus == :left && ENTER_KEYS.include?(key)
          return Messages::PaneFocusChanged.new(target: :right)
        end

        return Messages::NOOP if row.nil?

        return Messages::OpenTaskFolder.new(row: row) if key == "o"
        return verb_message(row, key) if VERB_KEYS.key?(key)
        return enter_message(row) if ENTER_KEYS.include?(key)

        Messages::NOOP
      end

      # Keys that work even when the cursor sits on an empty grid; row
      # is irrelevant for these so we resolve them first.
      def global_grid_message(key)
        return Messages::TERMINATE_REQUESTED if key == "q"
        return Messages::SHOW_HELP if key == "?"
        return Messages::OPEN_FILTER_PROMPT if key == "/"
        return Messages::OPEN_NEW_IDEA_PROMPT if key == "n"
        return Messages::DROP_SCOPED_PROJECT_IF_MISSING if key == "X"
        return Messages::ProjectScope.new(n: key.to_i) if key.is_a?(String) && key.match?(/\A[0-9]\z/)

        nil
      end

      def verb_message(row, key)
        # Verb-on-agent-running refusal pre-empts ConcurrentRunError
        # from `Hive::Lock`; the stale-pid escape hatch only fires when
        # the lock is *provably* dead (claude_pid_alive == false). Nil
        # (unknown) is treated as alive so we never dispatch a verb on
        # an indeterminate lock state. A nil suggested_command on the
        # escape hatch falls back to a flash so Shellwords.split(nil)
        # can never raise.
        if row.action_key == "agent_running"
          unless row.claude_pid_alive == false
            return Messages::Flash.new(text: "agent is running on this task; press Enter to view its log")
          end
          if row.suggested_command.nil?
            return Messages::Flash.new(text: "agent lock is stale but no recovery command available")
          end

          return dispatch_command_for(row.suggested_command)
        end

        # `r` (review) on a max_passes-hit REVIEW_STALE row is the
        # explicit "I edited the escalations file, retry now" gesture.
        # Enter on the same row routes to OpenReviewStaleFile (browse)
        # because auto-retry without edits would just produce the same
        # findings; `r` declares the edits are done and bypasses the
        # `retryable_review_stale?` gate in BubbleModel#recover_review.
        # Limited to `r` so other verbs (`b`/`p`/`d`/`P`) on a stale
        # review row keep flashing "no action available" — only the
        # review verb is semantically a retry.
        if key == "r" && row.action_key == "recover_review" && row.marker.to_s == "review_stale"
          return Messages::RecoverReview.new(row: row, force: true)
        end

        if row.suggested_command.nil?
          return Messages::Flash.new(text: "no action available — task is #{row.action_label}")
        end

        dispatch_command_for(row.suggested_command)
      end

      def enter_message(row)
        return Messages::OpenSummary.new(row: row) if finalize_complete_row?(row)
        return Messages::OpenRedStatusDetail.new(row: row) if red_detail_row?(row)

        case row.action_key
        when "review_findings" then Messages::OpenFindings.new(row: row)
        when "agent_running" then Messages::OpenLogTail.new(row: row)
        when "error" then error_message(row)
        when "recover_review" then Messages::RecoverReview.new(row: row)
        when "needs_input" then needs_input_message(row)
        else enter_fallback_message(row)
        end
      end

      def finalize_complete_row?(row)
        row.stage == "7-finalize" && row.marker.to_s == "complete"
      end

      # Enter on an `error` row routes to `RecoverError` (clear ERROR
      # marker + re-run) for non-kill-class failures — the case that
      # previously had no in-TUI affordance and required a shell-level
      # `hive markers clear`. Kill-class signal kills are auto-healed in
      # the background by BubbleModel; while the heal is in flight, fall
      # back to OpenLogTail so the user can still see the failure
      # context. ERROR markers without an `exit_code` attr (legacy or
      # hand-written) take the recovery path because there is no other
      # gesture available, and `hive markers clear --name ERROR` accepts
      # them.
      def error_message(row)
        attrs = row.attrs || {}
        return Messages::OpenLogTail.new(row: row) if KILL_CLASS_EXIT_CODES.include?(attrs["exit_code"].to_s)

        Messages::RecoverError.new(row: row)
      end

      def red_detail_row?(row)
        return false if row.nil?

        case row.action_key.to_s
        when "recover_review"
          recover_review_detail_row?(row)
        when "error"
          attrs = row.attrs || {}
          !KILL_CLASS_EXIT_CODES.include?(attrs["exit_code"].to_s)
        when "recover_execute"
          # EXECUTE_STALE rows expose the same diagnostic payload in
          # JSON but historically lacked a detail view. Opening the
          # view lets operators read the bounded summary + artifact
          # tail and refresh the diagnosis with `R`. The autofix
          # action is intentionally a no-op for these rows (they
          # require a manual fix); see PR #84 review finding #10 and
          # task_action.rb#suggested_next_action_payload.
          true
        else
          false
        end
      end

      def recover_review_detail_row?(row)
        return false if row.marker.to_s == "review_stale" && wall_clock_stale?(row)
        return false if max_passes_stale_with_escalations?(row)

        true
      end

      def wall_clock_stale?(row)
        (row.attrs || {})["reason"].to_s == "wall_clock"
      end

      def max_passes_stale_with_escalations?(row)
        Hive::TaskAction.max_passes_review_stale_with_escalations?(
          folder: row.folder, marker_name: row.marker, attrs: row.attrs
        )
      end

      # Enter on a `needs_input` row opens the row's input file in the
      # user's editor. Re-running the agent before edits would just
      # spawn against an unchanged state file — but the agent emitted
      # `<!-- WAITING -->` precisely because it wants human edits.
      # Execute waiting rows can override this with a structured
      # `next_action.kind=run` when editing cannot satisfy the gate
      # (for example `missing_research_output`).
      # BubbleModel owns any post-edit auto-continue rules; the verb
      # keys (`b`/`p`/`d`/`r`/`P`) remain the explicit manual rerun path.
      def needs_input_message(row)
        if run_next_action?(row)
          return Messages::Flash.new(text: "no action available — task is #{row.action_label}") if row.suggested_command.nil?

          return dispatch_command_for(row.suggested_command)
        end

        Messages::OpenInputEditor.new(row: row)
      end

      def run_next_action?(row)
        next_action = row.respond_to?(:next_action) ? row.next_action : nil
        next_action.is_a?(Hash) && next_action["kind"] == Hive::Schemas::NextActionKind::RUN
      end

      def enter_fallback_message(row)
        if row.action_key.to_s.start_with?("ready_") && row.suggested_command
          return dispatch_command_for(row.suggested_command)
        end

        text = ENTER_FLASH_MESSAGES[row.action_key]
        return Messages::Flash.new(text: text) if text

        Messages::NOOP
      end

      def triage_message(key:, row:)
        return Messages::BACK if ESCAPE_KEYS.include?(key)
        return Messages::TRIAGE_CURSOR_DOWN if DOWN_KEYS.include?(key)
        return Messages::TRIAGE_CURSOR_UP if UP_KEYS.include?(key)
        return triage_space_message(row) if key == " " || key == :space

        # Triage d/a/r are payload-free singletons. The handler in
        # BubbleModel resolves the target argv from `triage_state`'s
        # captured slug+folder rather than the live grid row, which a
        # 1Hz snapshot poll could have re-pointed at a different task
        # between triage open and the keystroke. row may be nil here
        # (filter hid the parent row mid-triage); the handler still
        # works because it ignores row entirely.
        case key
        when "d" then Messages::TRIAGE_DEVELOP
        when "a" then Messages::BULK_ACCEPT
        when "r" then Messages::BULK_REJECT
        else Messages::NOOP
        end
      end

      def triage_space_message(row)
        return Messages::NOOP if row.nil?

        Messages::ToggleFinding.new(row: row)
      end

      def log_tail_message(key:, row:) # rubocop:disable Lint/UnusedMethodArgument
        return Messages::BACK if ESCAPE_KEYS.include?(key) || key == "q"

        Messages::NOOP
      end

      def red_status_detail_message(key:, row:)
        return Messages::BACK if ESCAPE_KEYS.include?(key) || key == "q"
        return Messages::RedStatusAutofix.new(row: row) if ENTER_KEYS.include?(key) && row
        return Messages::OpenManualFix.new(row: row) if key == "f" && row
        return Messages::RefreshRedStatusDiagnosis.new(row: row) if key == "R" && row
        # Grid-mode verb keys (b/p/d/r/P/F/a) silently no-oping in the
        # detail view conflicts with the muscle memory documented in
        # wiki/commands/tui.md — notably `r` is the in-grid force-retry
        # gesture (PR #72). Flash an explicit refusal instead so the
        # operator sees the mode boundary.
        if VERB_KEYS.key?(key)
          return Messages::Flash.new(text: "verb keys are grid-mode only — Esc to return")
        end

        Messages::NOOP
      end

      # Filter-prompt mode keystrokes. Update consumes the FilterChar*
      # messages to extend/shrink/commit/cancel the buffer; KeyMap is
      # the producer side. Esc routes to FILTER_CANCELLED (not BACK) so
      # `apply_filter_cancelled` clears `filter_buffer` rather than
      # leaking a half-typed query into the next `/` open.
      def filter_message(key:, row:) # rubocop:disable Lint/UnusedMethodArgument
        return Messages::FILTER_CANCELLED if ESCAPE_KEYS.include?(key)
        return Messages::FILTER_COMMITTED if ENTER_KEYS.include?(key)
        return Messages::FILTER_CHAR_DELETED if key == :key_backspace
        # See new_idea_message: BubbleModel emits `:space` for SPACE
        # keypresses; map back to a literal space so slug filters with
        # spaces (e.g., "rss feeds") work.
        return Messages::FilterCharAppended.new(char: " ") if key == :space
        return Messages::FilterCharAppended.new(char: key) if printable_filter_char?(key)

        Messages::NOOP
      end

      # Single printable character (string of length 1). Excludes
      # `:key_*` symbols and the `:space` symbol. Space-as-char (the
      # literal " " string) is allowed so users can filter on slugs
      # containing spaces, even though Hive slugs don't currently use
      # them — keeps the surface forgiving.
      def printable_filter_char?(key)
        key.is_a?(String) && key.length == 1
      end

      # Help overlay dismisses on any key — matches the curses-era
      # `Render::HelpOverlay#show` behaviour. Any printable char or
      # special key returns BACK; the cursor singletons aren't special-
      # cased here because they should also dismiss.
      def help_message(key:, row:) # rubocop:disable Lint/UnusedMethodArgument
        Messages::BACK
      end

      # New-idea prompt mode — same key shape as `:filter` mode but
      # produces NewIdea* messages. Esc cancels (clears the buffer +
      # returns to :grid); Enter submits (BubbleModel handles the
      # subprocess dispatch); Backspace deletes the trailing character;
      # any printable char appends. Space arrives as the `:space`
      # symbol from BubbleModel#bubble_key_to_keymap, so it must be
      # mapped explicitly to a literal space — without this branch,
      # multi-word titles like "rss feeds" would land as "rssfeeds".
      def new_idea_message(key:, row:) # rubocop:disable Lint/UnusedMethodArgument
        return Messages::NEW_IDEA_CANCELLED if ESCAPE_KEYS.include?(key)
        return Messages::NEW_IDEA_SUBMITTED if ENTER_KEYS.include?(key)
        return Messages::NEW_IDEA_CHAR_DELETED if key == :key_backspace
        return Messages::NEW_IDEA_CHAR_DELETED_FORWARD if key == :key_delete
        return Messages::NEW_IDEA_CURSOR_LEFT if key == :key_left
        return Messages::NEW_IDEA_CURSOR_RIGHT if key == :key_right
        return Messages::NEW_IDEA_CURSOR_HOME if key == :key_home || key == :key_ctrl_a
        return Messages::NEW_IDEA_CURSOR_END if key == :key_end || key == :key_ctrl_e
        return Messages::NewIdeaPasteRequested.new(raw_text: "") if key == :key_ctrl_v
        return Messages::NewIdeaTextInserted.new(text: " ") if key == :space
        return Messages::NewIdeaTextInserted.new(text: key) if printable_filter_char?(key)

        Messages::NOOP
      end

      # Project chooser shown before the title prompt when `n` starts
      # from ★ All projects. Keep the key surface intentionally narrow:
      # choose with Enter, move with j/k or arrows, cancel with Esc/q.
      def new_idea_project_message(key:, row:) # rubocop:disable Lint/UnusedMethodArgument
        return Messages::NEW_IDEA_CANCELLED if ESCAPE_KEYS.include?(key) || key == "q"
        return Messages::NEW_IDEA_PROJECT_SELECTED if ENTER_KEYS.include?(key)
        return Messages::NEW_IDEA_PROJECT_CURSOR_DOWN if DOWN_KEYS.include?(key)
        return Messages::NEW_IDEA_PROJECT_CURSOR_UP if UP_KEYS.include?(key)

        Messages::NOOP
      end

      # Shared DispatchCommand builder. `argv[1]` is the workflow verb
      # (`brainstorm`/`plan`/`develop`/`review`/`pr`/`archive`); cached
      # at construction time so SubprocessExited can flash by verb name.
      def dispatch_command_for(suggested_command)
        argv = Shellwords.split(suggested_command)
        Messages::DispatchCommand.new(argv: argv, verb: argv[1])
      end
    end
  end
end
