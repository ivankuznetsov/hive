require "bubbletea"
require "hive"
require "hive/task"
require "hive/findings"
require "hive/tui/model"
require "hive/tui/messages"
require "hive/tui/key_map"
require "hive/tui/update"
require "hive/tui/snapshot"
require "hive/tui/triage_state"
require "hive/tui/log_tail"
require "hive/tui/subprocess"
require "hive/tui/views/grid"
require "hive/tui/views/triage"
require "hive/tui/views/log_tail"
require "hive/tui/views/help_overlay"
require "hive/tui/views/filter_prompt"

module Hive
  module Tui
    # Bubbletea::Model adapter that wraps `Hive::Tui::Model` (frozen Data
    # record) and orchestrates the MVU loop. Stateful internally — the
    # `@hive_model` attribute reassigns on every `#update` — but every
    # transition still flows through `Update.apply` so the state changes
    # remain pure-function-tested in isolation.
    #
    # Responsibilities split:
    #   * Translate framework messages (KeyMessage / WindowSizeMessage)
    #     into Hive Messages before delegation.
    #   * Handle messages that need a runner reference (DispatchCommand
    #     wraps takeover_command with `runner.method(:send)` — Update
    #     can't, since it's runner-agnostic).
    #   * Handle messages that perform synchronous I/O (OpenFindings,
    #     OpenLogTail, BulkAccept, BulkReject, ToggleFinding) — same
    #     pattern as the curses path's run_triage / run_quiet! calls.
    #     I/O lands here, not in Update, to keep Update pure.
    #   * Dispatch view by `model.mode` to one of the Views modules.
    #
    # The `dispatch:` lambda is set externally (App.run_charm wires
    # `runner.method(:send)`) so this class can be unit-tested with a
    # plain capture lambda — same seam as Subprocess.takeover_command.
    class BubbleModel
      include Bubbletea::Model

      attr_reader :hive_model

      def initialize(hive_model: Hive::Tui::Model.initial, dispatch: ->(_msg) { })
        @hive_model = hive_model
        @dispatch = dispatch
      end

      # Late binding so App.run_charm can wire the runner reference
      # after construction (Bubbletea::Runner.new is called with the
      # model, then we call `runner.method(:send)` to get the dispatcher).
      def dispatch=(callable)
        @dispatch = callable
      end

      # The init Cmd seeds a recurring `YieldTick` so the main loop
      # yields to Ruby threads between input polls — see
      # `Hive::Tui::Messages::YieldTick` for the underlying GVL-starvation
      # rationale. Without this seed, `StateSource#refresh_once` (which
      # runs on a background thread) takes 5-10s per poll under
      # `runner.run`'s tight loop.
      def init
        [ self, yield_tick_cmd ]
      end

      # @api private
      # Recurring 10ms tick. The callback yields the GVL via
      # `Thread.pass` and returns YIELD_TICK; update sees it, returns
      # the same tick again to keep the cycle going.
      def yield_tick_cmd
        Bubbletea.tick(0.01) do
          Thread.pass
          Hive::Tui::Messages::YIELD_TICK
        end
      end

      def update(message)
        hive_message = translate(message)

        # YieldTick is the only message that loops back into a tick
        # — re-schedule on every observation so the GVL-yield cycle
        # never stops.
        return [ self, yield_tick_cmd ] if hive_message.is_a?(Hive::Tui::Messages::YieldTick)

        # Side-effect-bearing messages that need a runner reference or
        # perform synchronous I/O are handled here; everything else
        # delegates to Update.apply.
        cmd_or_model = handle_side_effect(hive_message)
        if cmd_or_model
          new_model, cmd = cmd_or_model
          @hive_model = new_model if new_model
          return [ self, cmd ]
        end

        new_model, cmd = Hive::Tui::Update.apply(@hive_model, hive_message)
        @hive_model = new_model
        [ self, cmd ]
      end

      def view
        case @hive_model.mode
        when :grid then Views::Grid.render(@hive_model)
        when :triage then Views::Triage.render(@hive_model)
        when :log_tail then Views::LogTail.render(@hive_model)
        when :help then Views::HelpOverlay.render(@hive_model)
        when :filter then compose_filter_view
        else Views::Grid.render(@hive_model)
        end
      end

      private

      # Bubbletea::KeyMessage → Hive Message via KeyMap.message_for.
      # Bubbletea::WindowSizeMessage → Messages::WindowSized.
      # Everything else (Hive Messages we sent ourselves via
      # `runner.send(...)`, or framework messages we don't translate)
      # passes through unchanged.
      def translate(message)
        case message
        when Bubbletea::KeyMessage
          translate_key(message)
        when Bubbletea::WindowSizeMessage
          Hive::Tui::Messages::WindowSized.new(cols: message.width, rows: message.height)
        else
          message
        end
      end

      # Translate a Bubbletea::KeyMessage to a Hive Message via the pure
      # KeyMap. Row context is the row currently under the cursor (nil
      # if the visible grid is empty); KeyMap uses it to refuse verbs
      # on stale-pid rows and to synthesize argv from suggested_command.
      def translate_key(key_message)
        key = bubble_key_to_keymap(key_message)
        row = current_row
        Hive::Tui::KeyMap.message_for(mode: @hive_model.mode, key: key, row: row)
      rescue ArgumentError
        # Unknown mode (defensive): treat as Noop. Should never fire
        # since `mode` is constrained by Update transitions.
        Hive::Tui::Messages::NOOP
      end

      # Bubbletea::KeyMessage → KeyMap-shaped key (single-char String or
      # `:key_*` Symbol). Mirror the same surface KeyMap accepts from
      # the curses backend's curses_keys translator.
      def bubble_key_to_keymap(km)
        return :key_enter if km.enter?
        return :key_escape if km.esc?
        return :key_up if km.up?
        return :key_down if km.down?
        return :key_backspace if km.backspace?
        return :space if km.space?

        char = km.char
        char.is_a?(String) && !char.empty? ? char[0] : Hive::Tui::Messages::NOOP
      end

      # The cursor's current row, derived from snapshot + scope + filter.
      # KeyMap consults this for verb-on-running-agent refusals and for
      # row-driven action_key dispatch (review_findings, agent_running,
      # needs_input, etc.).
      def current_row
        snap = @hive_model.snapshot
        return nil if snap.nil? || @hive_model.cursor.nil?

        visible = snap.scope_to_project_index(@hive_model.scope).filter_by_slug(@hive_model.filter)
        visible.row_at(@hive_model.cursor)
      end

      # Returns [new_hive_model, cmd] for the side-effect-bearing
      # messages, or nil to indicate "delegate to Update.apply".
      def handle_side_effect(message)
        case message
        when Hive::Tui::Messages::DispatchCommand
          dispatch_command(message)
        when Hive::Tui::Messages::OpenFindings
          open_findings(message.row)
        when Hive::Tui::Messages::OpenLogTail
          open_log_tail(message.row)
        when Hive::Tui::Messages::ToggleFinding
          toggle_finding(message.row)
        when Hive::Tui::Messages::BulkAccept
          bulk_accept(message.slug)
        when Hive::Tui::Messages::BulkReject
          bulk_reject(message.slug)
        end
      end

      def dispatch_command(message)
        cmd = Hive::Tui::Subprocess.takeover_command(message.argv, dispatch: @dispatch)
        [ @hive_model, cmd ]
      end

      # Synchronous I/O: open the review file, build a TriageState,
      # flip mode. If the file is missing (concurrent archive) we flash
      # and stay in grid mode rather than entering an empty triage view.
      def open_findings(row)
        task = Hive::Task.new(row.folder)
        review_path = Hive::Findings.review_path_for(task)

        document = Hive::Findings::Document.new(review_path)
        state = Hive::Tui::TriageState.new(
          slug: row.slug, findings: document.findings, review_path: review_path
        )
        [ @hive_model.with(mode: :triage, triage_state: state), nil ]
      rescue Hive::NoReviewFile, Hive::InvalidTaskPath, Errno::ENOENT
        [ flashed("no review file for #{row.slug}"), nil ]
      end

      # Open the most recent log file under the row's `.hive/logs/`,
      # build a Tail, flip mode. Race-tolerant: if the file disappears
      # between resolve and open, flash instead of crashing.
      def open_log_tail(row)
        task = Hive::Task.new(row.folder)
        log_dir = File.join(task.folder, "logs")
        log_path = Hive::Tui::LogTail::FileResolver.latest(log_dir)
        return [ flashed("no logs for #{row.slug}"), nil ] if log_path.nil?

        tail = Hive::Tui::LogTail::Tail.new(log_path)
        tail.open!
        wrapper = LogTailContext.new(tail: tail, claude_pid_alive: row.claude_pid_alive)
        [ @hive_model.with(mode: :log_tail, tail_state: wrapper), nil ]
      rescue Hive::InvalidTaskPath, Errno::ENOENT, Errno::EACCES
        [ flashed("log file gone"), nil ]
      end

      # Wrapper exposing `path`/`claude_pid_alive`/`lines(n)` to
      # Views::LogTail. Carries the underlying Tail so we can call
      # `close!` on Back without leaking file descriptors.
      class LogTailContext
        attr_reader :tail, :claude_pid_alive

        def initialize(tail:, claude_pid_alive:)
          @tail = tail
          @claude_pid_alive = claude_pid_alive
        end

        def path
          @tail.path
        end

        def lines(count)
          @tail.lines(count)
        end
      end

      # Toggle accept/reject on the current finding, then reload the
      # findings document. The cursor relocator preserves position
      # across re-orderings (TriageState#relocate_cursor).
      def toggle_finding(row)
        state = @hive_model.triage_state
        return [ @hive_model, nil ] if state.nil?

        finding = state.current_finding
        return [ @hive_model, nil ] if finding.nil?

        argv = state.toggle_command(finding)
        exit_code, _, err = Hive::Tui::Subprocess.run_quiet!(argv)
        if exit_code != 0
          flash_text = "toggle failed: #{err.lines.first&.chomp || "exit #{exit_code}"}"
          return [ flashed(flash_text), nil ]
        end

        reload_findings_into_state(state, row)
      end

      def bulk_accept(slug)
        bulk_run(direction: :accept, slug: slug)
      end

      def bulk_reject(slug)
        bulk_run(direction: :reject, slug: slug)
      end

      def bulk_run(direction:, slug:)
        state = @hive_model.triage_state
        return [ @hive_model, nil ] if state.nil? || state.slug != slug

        argv = state.bulk_command(direction)
        exit_code, _, err = Hive::Tui::Subprocess.run_quiet!(argv)
        if exit_code != 0
          flash_text = "#{direction} failed: #{err.lines.first&.chomp || "exit #{exit_code}"}"
          return [ flashed(flash_text), nil ]
        end

        reload_findings_into_state(state, nil)
      end

      def reload_findings_into_state(state, _row)
        document = Hive::Findings::Document.new(state.review_path)
        state.relocate_cursor(document.findings)
        [ @hive_model.with(triage_state: state), nil ]
      rescue Hive::NoReviewFile, Errno::ENOENT
        [ @hive_model.with(mode: :grid, triage_state: nil, flash: "review file gone", flash_set_at: Time.now), nil ]
      end

      def flashed(text)
        @hive_model.with(flash: text, flash_set_at: Time.now)
      end

      # Filter mode: Views::Grid for the underlying frame; replace the
      # bottom hint line with the filter prompt. Bubble Tea diffs
      # against the previous frame so a one-line change paints
      # cheaply.
      def compose_filter_view
        grid_lines = Views::Grid.render(@hive_model).lines
        prompt = Views::FilterPrompt.render(@hive_model)
        if grid_lines.empty?
          prompt
        else
          # The status line is always the trailing line — replace it
          # in place so layout doesn't shift when the user toggles
          # filter mode.
          grid_lines[-1] = prompt
          grid_lines.join
        end
      end
    end
  end
end
