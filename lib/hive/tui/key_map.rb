require "shellwords"
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
      # `P` distinguishes `pr` from `plan` since both start with `p`.
      VERB_KEYS = {
        "b" => "brainstorm",
        "p" => "plan",
        "d" => "develop",
        "r" => "review",
        "P" => "pr",
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
      # opens the agent log instead (see `enter_message`) so the user
      # can see WHY the agent failed without leaving the TUI.
      ENTER_FLASH_MESSAGES = {
        "archived" => "task is archived; no further action",
        "recover_execute" => "task needs recovery — open findings to re-prioritise",
        "recover_review" => "task needs recovery — clear the stale review marker"
      }.freeze

      # @api public
      def message_for(mode:, key:, row:)
        case mode
        when :grid then grid_message(key: key, row: row)
        when :triage then triage_message(key: key, row: row)
        when :log_tail then log_tail_message(key: key, row: row)
        when :filter then filter_message(key: key, row: row)
        when :help then help_message(key: key, row: row)
        else raise ArgumentError, "unknown mode: #{mode.inspect}"
        end
      end

      def grid_message(key:, row:)
        global = global_grid_message(key)
        return global if global

        # Cursor navigation must work even when the cursor sits on no
        # visible row — without this branch j/k after a filter that
        # hides the prior cursor returns NOOP, leaving the user wedged
        # with visible matches and no way to navigate to them. The
        # downstream apply_cursor_* handlers re-derive a usable cursor
        # from the visible snapshot when the current cursor is invalid.
        return Messages::CURSOR_DOWN if DOWN_KEYS.include?(key)
        return Messages::CURSOR_UP if UP_KEYS.include?(key)
        return Messages::NOOP if row.nil?

        return verb_message(row) if VERB_KEYS.key?(key)
        return enter_message(row) if ENTER_KEYS.include?(key)

        Messages::NOOP
      end

      # Keys that work even when the cursor sits on an empty grid; row
      # is irrelevant for these so we resolve them first.
      def global_grid_message(key)
        return Messages::TERMINATE_REQUESTED if key == "q"
        return Messages::SHOW_HELP if key == "?"
        return Messages::OPEN_FILTER_PROMPT if key == "/"
        return Messages::ProjectScope.new(n: key.to_i) if key.is_a?(String) && key.match?(/\A[0-9]\z/)

        nil
      end

      def verb_message(row)
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

        if row.suggested_command.nil?
          return Messages::Flash.new(text: "no action available — task is #{row.action_label}")
        end

        dispatch_command_for(row.suggested_command)
      end

      def enter_message(row)
        case row.action_key
        when "review_findings" then Messages::OpenFindings.new(row: row)
        when "agent_running" then Messages::OpenLogTail.new(row: row)
        when "error" then Messages::OpenLogTail.new(row: row)
        when "needs_input" then needs_input_message(row)
        else enter_fallback_message(row)
        end
      end

      # Enter on a `needs_input` row dispatches the row's suggested
      # command — same effect as pressing the verb keystroke for that
      # action. The TUI is for keystroke-driven dispatch; editing the
      # state file belongs in the user's own shell.
      def needs_input_message(row)
        if row.suggested_command.nil?
          return Messages::Flash.new(text: "no command available — task is #{row.action_label}")
        end

        dispatch_command_for(row.suggested_command)
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

      # Filter-prompt mode keystrokes. Update consumes the FilterChar*
      # messages to extend/shrink/commit/cancel the buffer; KeyMap is
      # the producer side. Esc routes to FILTER_CANCELLED (not BACK) so
      # `apply_filter_cancelled` clears `filter_buffer` rather than
      # leaking a half-typed query into the next `/` open.
      def filter_message(key:, row:) # rubocop:disable Lint/UnusedMethodArgument
        return Messages::FILTER_CANCELLED if ESCAPE_KEYS.include?(key)
        return Messages::FILTER_COMMITTED if ENTER_KEYS.include?(key)
        return Messages::FILTER_CHAR_DELETED if key == :key_backspace
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
