require "shellwords"
require "hive/tui/snapshot"
require "hive/tui/messages"

module Hive
  module Tui
    # Pure-data keystroke -> action mapper. The render layer translates
    # framework key events (curses or bubbletea) to either a single-
    # character String or a `:key_*` Symbol before calling either
    # `dispatch(mode:, key:, row:)` (curses path; returns
    # `[verb, payload]` tuples) or `message_for(mode:, key:, row:)`
    # (charm path; returns `Hive::Tui::Messages::*`). KeyMap stays
    # backend-free so it's unit-testable without a tty.
    #
    # During the U1-U10 migration window both APIs coexist. Internally
    # `dispatch` is a thin shim over `message_for` — single source of
    # truth, no risk of the two surfaces drifting. U11 deletes the
    # shim along with the curses code path.
    #
    # The same `key` may bind to different actions across modes:
    # `a` is `archive` verb dispatch in `:grid` mode and `bulk_accept`
    # in `:triage` mode; that's why `mode:` is a required keyword. The
    # row-shaped argv we hand back for grid-mode verb keys comes from
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
      ENTER_FLASH_MESSAGES = {
        "archived" => "task is archived; no further action",
        "error" => "task is in error state; inspect via $EDITOR",
        "recover_execute" => "task needs recovery — open findings to re-prioritise",
        "recover_review" => "task needs recovery — clear the stale review marker"
      }.freeze

      # ---- Primary API: returns Messages (used by the charm backend) ----
      def message_for(mode:, key:, row:)
        case mode
        when :grid then grid_message(key: key, row: row)
        when :triage then triage_message(key: key, row: row)
        when :log_tail then log_tail_message(key: key, row: row)
        when :filter then filter_message(key: key, row: row)
        else raise ArgumentError, "unknown mode: #{mode.inspect}"
        end
      end

      # ---- Back-compat shim: returns [verb, payload] tuples ----
      # Used by the curses path through U10. Every Message produced by
      # `message_for` has a 1:1 reverse mapping back to the legacy
      # tuple shape — this is the only place that mapping lives, so
      # the two surfaces can't drift.
      def dispatch(mode:, key:, row:)
        message_to_tuple(message_for(mode: mode, key: key, row: row))
      end

      def grid_message(key:, row:)
        global = global_grid_message(key)
        return global if global

        return Messages::NOOP if row.nil?

        return verb_message(row) if VERB_KEYS.key?(key)
        return enter_message(row) if ENTER_KEYS.include?(key)
        return Messages::CURSOR_DOWN if DOWN_KEYS.include?(key)
        return Messages::CURSOR_UP if UP_KEYS.include?(key)

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
        when "needs_input" then needs_input_message(row)
        else enter_fallback_message(row)
        end
      end

      # Enter on a `needs_input` row dispatches the row's suggested
      # command — same effect as pressing the verb keystroke for that
      # action. The earlier $EDITOR integration was removed because the
      # spawn-an-editor-from-curses dance broke alt-screen handoff on
      # several terminals; the TUI is for keystroke-driven dispatch,
      # editing belongs in the user's own shell.
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
        return Messages::CURSOR_DOWN if DOWN_KEYS.include?(key)
        return Messages::CURSOR_UP if UP_KEYS.include?(key)
        return triage_space_message(row) if key == " " || key == :space
        return Messages::NOOP if row.nil?

        case key
        when "d"
          Messages::DispatchCommand.new(
            argv: [ "hive", "develop", row.slug, "--from", "4-execute" ],
            verb: "develop"
          )
        when "a" then Messages::BulkAccept.new(slug: row.slug)
        when "r" then Messages::BulkReject.new(slug: row.slug)
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

      def filter_message(key:, row:) # rubocop:disable Lint/UnusedMethodArgument
        return Messages::BACK if ESCAPE_KEYS.include?(key)

        Messages::NOOP
      end

      # Shared DispatchCommand builder. `argv[1]` is the workflow verb
      # (`brainstorm`/`plan`/`develop`/`review`/`pr`/`archive`); cached
      # at construction time so SubprocessExited can flash by verb name.
      def dispatch_command_for(suggested_command)
        argv = Shellwords.split(suggested_command)
        Messages::DispatchCommand.new(argv: argv, verb: argv[1])
      end

      # ---- Back-compat translation table ----
      # Single source of truth for Message → legacy tuple. Every
      # Message produced by `message_for` must round-trip through here.
      def message_to_tuple(message)
        case message
        when Messages::DispatchCommand then [ :dispatch_command, message.argv ]
        when Messages::Flash then [ :flash, message.text ]
        when Messages::OpenFindings then [ :open_findings, message.row ]
        when Messages::OpenLogTail then [ :open_log_tail, message.row ]
        when Messages::ToggleFinding then [ :toggle_finding, message.row ]
        when Messages::BulkAccept then [ :bulk_accept, message.slug ]
        when Messages::BulkReject then [ :bulk_reject, message.slug ]
        when Messages::ProjectScope then [ :project_scope, message.n ]
        when Messages::ShowHelp then [ :help, nil ]
        when Messages::OpenFilterPrompt then [ :filter, nil ]
        when Messages::Back then [ :back, nil ]
        when Messages::CursorDown then [ :cursor_down, nil ]
        when Messages::CursorUp then [ :cursor_up, nil ]
        when Messages::Noop then [ :noop, nil ]
        when Messages::TerminateRequested then [ :quit, nil ]
        else
          raise ArgumentError, "no tuple mapping for #{message.class.name}"
        end
      end
    end
  end
end
