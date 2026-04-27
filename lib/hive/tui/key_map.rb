require "shellwords"
require "hive/tui/snapshot"

module Hive
  module Tui
    # Pure-data keystroke -> action mapper. The render layer translates
    # `Curses.getch` output to either a single-character String or a
    # `:key_*` Symbol before calling `dispatch(mode:, key:, row:)`; this
    # keeps KeyMap free of curses so it stays unit-testable without a
    # tty. Every code path returns a two-element [verb, payload] tuple
    # and never invokes a subprocess on its own — TUI side effects live
    # in U4 (Subprocess) and U5+ (render loop), not here.
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

      ENTER_KEYS = [ :key_enter, "\r", "\n" ].freeze
      ESCAPE_KEYS = [ :key_escape, "\e" ].freeze
      DOWN_KEYS = [ :key_down, "j" ].freeze
      UP_KEYS = [ :key_up, "k" ].freeze

      # Row action_keys with no `suggested_command`, mapped to the
      # contextual flash message Enter (and verb keys) should surface.
      ENTER_FLASH_MESSAGES = {
        "archived" => "task is archived; no further action",
        "error" => "task is in error state; inspect via $EDITOR",
        "recover_execute" => "task needs recovery — open findings to re-prioritise",
        "recover_review" => "task needs recovery — clear the stale review marker"
      }.freeze

      def dispatch(mode:, key:, row:)
        case mode
        when :grid then dispatch_grid(key: key, row: row)
        when :triage then dispatch_triage(key: key, row: row)
        when :log_tail then dispatch_log_tail(key: key, row: row)
        when :filter then dispatch_filter(key: key, row: row)
        else raise ArgumentError, "unknown mode: #{mode.inspect}"
        end
      end

      def dispatch_grid(key:, row:)
        global = global_grid_action(key)
        return global if global

        return [ :noop, nil ] if row.nil?

        return verb_action(row) if VERB_KEYS.key?(key)
        return enter_action(row) if ENTER_KEYS.include?(key)
        return [ :cursor_down, nil ] if DOWN_KEYS.include?(key)
        return [ :cursor_up, nil ] if UP_KEYS.include?(key)

        [ :noop, nil ]
      end

      # Keys that work even when the cursor sits on an empty grid; row
      # is irrelevant for these so we resolve them first.
      def global_grid_action(key)
        return [ :quit, nil ] if key == "q"
        return [ :help, nil ] if key == "?"
        return [ :filter, nil ] if key == "/"
        return [ :project_scope, key.to_i ] if key.is_a?(String) && key.match?(/\A[0-9]\z/)

        nil
      end

      def verb_action(row)
        # Verb-on-agent-running refusal pre-empts ConcurrentRunError
        # from `Hive::Lock`; the stale-pid escape hatch only fires when
        # the lock is *provably* dead (claude_pid_alive == false). Nil
        # (unknown) is treated as alive so we never dispatch a verb on
        # an indeterminate lock state. A nil suggested_command on the
        # escape hatch falls back to a flash so Shellwords.split(nil)
        # can never raise.
        if row.action_key == "agent_running"
          return [ :flash, "agent is running on this task; press Enter to view its log" ] unless row.claude_pid_alive == false
          return [ :flash, "agent lock is stale but no recovery command available" ] if row.suggested_command.nil?

          return [ :dispatch_command, Shellwords.split(row.suggested_command) ]
        end

        return [ :flash, "no action available — task is #{row.action_label}" ] if row.suggested_command.nil?

        [ :dispatch_command, Shellwords.split(row.suggested_command) ]
      end

      def enter_action(row)
        case row.action_key
        when "review_findings" then [ :open_findings, row ]
        when "agent_running" then [ :open_log_tail, row ]
        when "needs_input" then [ :open_editor, row ]
        else enter_fallback(row)
        end
      end

      def enter_fallback(row)
        if row.action_key.to_s.start_with?("ready_") && row.suggested_command
          return [ :dispatch_command, Shellwords.split(row.suggested_command) ]
        end

        message = ENTER_FLASH_MESSAGES[row.action_key]
        return [ :flash, message ] if message

        [ :noop, nil ]
      end

      def dispatch_triage(key:, row:)
        return [ :back, nil ] if ESCAPE_KEYS.include?(key)
        return [ :cursor_down, nil ] if DOWN_KEYS.include?(key)
        return [ :cursor_up, nil ] if UP_KEYS.include?(key)
        return triage_space_action(row) if key == " " || key == :space
        return [ :noop, nil ] if row.nil?

        case key
        when "d" then [ :dispatch_command, [ "hive", "develop", row.slug, "--from", "4-execute" ] ]
        when "a" then [ :bulk_accept, row.slug ]
        when "r" then [ :bulk_reject, row.slug ]
        else [ :noop, nil ]
        end
      end

      def triage_space_action(row)
        return [ :noop, nil ] if row.nil?

        [ :toggle_finding, row ]
      end

      def dispatch_log_tail(key:, row:) # rubocop:disable Lint/UnusedMethodArgument
        return [ :back, nil ] if ESCAPE_KEYS.include?(key) || key == "q"

        [ :noop, nil ]
      end

      def dispatch_filter(key:, row:) # rubocop:disable Lint/UnusedMethodArgument
        return [ :back, nil ] if ESCAPE_KEYS.include?(key)

        [ :noop, nil ]
      end
    end
  end
end
