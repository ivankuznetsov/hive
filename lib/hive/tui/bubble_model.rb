require "bubbletea"
require "hive"
require "hive/task"
require "hive/findings"
require "hive/tui/debug"
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

      # Exit codes that mean "the agent was killed by a signal", not
      # "the agent ran and decided to fail". 130 = SIGINT (Ctrl-C);
      # 137 = SIGKILL; 143 = SIGTERM (which fires when the user
      # quits the TUI mid-takeover and the pgroup forwards the signal
      # to in-flight children). Tasks left with `:error reason=exit_code
      # exit_code=<one of these>` markers are interrupted, not broken —
      # the file-system state is intact, just the marker says "stopped".
      # The auto-healer in `auto_heal_kill_class_errors` clears these
      # markers in the background so the TUI doesn't permanently
      # display "Error" rows the user can resume by simply re-running.
      KILL_CLASS_EXIT_CODES = %w[130 137 143].freeze

      def initialize(hive_model: Hive::Tui::Model.initial, dispatch: ->(_msg) { })
        @hive_model = hive_model
        @dispatch = dispatch
        # `@healed_folders` is touched from the main runner thread
        # (`auto_heal_kill_class_errors` registers folders before
        # spawning heals) AND from heal Threads (which evict on
        # failure so the next poll retries). The mutex serializes
        # both — Hash#[]=/`#delete` are not GVL-atomic across multiple
        # writers under MRI.
        @healed_folders = {} # folder path → Time.now
        @healed_folders_mutex = Mutex.new
        # F8: track in-flight heal Threads so App.run_charm's ensure
        # block can join-with-timeout-then-kill at TUI exit. Without
        # this, heal threads quitting mid-flight became zombies after
        # the runner tore down. Same mutex covers both fields — both
        # are touched from the same paths.
        @heal_threads = []
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
      rescue StandardError => e
        # Last-resort safety net. Every I/O-doing handler in
        # `handle_side_effect` lists its plausible failure modes
        # explicitly (see `open_findings`, `open_log_tail`, …) and
        # converts them into a flash. This catches the
        # *unanticipated* ones — a new Errno from a future fs feature,
        # a YAML parse error from a malformed reviewer file, a
        # Bubbletea framework message we don't yet handle. Without
        # this rescue, the exception unwinds out of `Bubbletea::Runner.run`
        # and tears down the alt-screen mid-frame, dumping the user back
        # to the shell. With it: a flash + the TUI keeps going. The
        # exception class + message are written to the debug log so
        # operators with `HIVE_TUI_DEBUG=1` can diagnose without
        # reproducing.
        Hive::Tui::Debug.log("bubble_model", "rescued #{e.class.name}: #{e.message}")
        @hive_model = @hive_model.with(
          flash: "internal error: #{e.class.name.split('::').last}: #{e.message[0, 80]}",
          flash_set_at: Time.now
        )
        [ self, nil ]
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
      rescue ArgumentError => e
        # Unknown mode (defensive): treat as Noop. Should never fire
        # since `mode` is constrained by Update transitions; logging
        # here is the only way a regression in Update mode-handling
        # would surface to an operator (otherwise: keystroke silently
        # does nothing, no flash, no signal).
        Hive::Tui::Debug.log(
          "keymap",
          "ArgumentError mode=#{@hive_model.mode.inspect} key=#{key.inspect}: #{e.message}"
        )
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
      #
      # `SnapshotArrived` is special-cased here for the kill-class
      # auto-healer (signal-killed tasks shouldn't display as "Error"
      # forever — the file state IS intact, the marker is just stale).
      # We return nil after kicking off the heal so `Update.apply`
      # still applies the snapshot; the next poll picks up the cleared
      # state.
      def handle_side_effect(message)
        case message
        when Hive::Tui::Messages::SnapshotArrived
          auto_heal_kill_class_errors(message.snapshot)
          nil
        when Hive::Tui::Messages::SubprocessExited
          diagnose_subprocess_exit(message)
        when Hive::Tui::Messages::DispatchCommand
          dispatch_command(message)
        when Hive::Tui::Messages::OpenFindings
          open_findings(message.row)
        when Hive::Tui::Messages::OpenLogTail
          open_log_tail(message.row)
        when Hive::Tui::Messages::LogTailPoll
          poll_log_tail
        when Hive::Tui::Messages::Back
          # F6: log_tail dismissal must close the underlying File or
          # every open/dismiss cycle leaks one FD. Side-effect-only —
          # return nil so Update.apply still handles the mode flip
          # and tail_state clearing.
          close_tail_if_log_tail
          nil
        when Hive::Tui::Messages::ToggleFinding
          toggle_finding(message.row)
        when Hive::Tui::Messages::BulkAccept
          bulk_accept(message.slug)
        when Hive::Tui::Messages::BulkReject
          bulk_reject(message.slug)
        end
      end

      def close_tail_if_log_tail
        return unless @hive_model.mode == :log_tail

        wrapper = @hive_model.tail_state
        wrapper&.tail&.close!
      end

      # Drain new bytes from the active Tail and reschedule the next
      # poll if the user is still viewing the log. Mode-change-out (Esc
      # / `q` flips back to :grid and clears tail_state) stops the
      # cycle so we don't keep waking the loop for a closed tail.
      def poll_log_tail
        wrapper = @hive_model.tail_state
        return [ @hive_model, nil ] if wrapper.nil? || @hive_model.mode != :log_tail

        wrapper.tail.poll!
        [ @hive_model, log_tail_poll_cmd ]
      end

      # Intercept SubprocessExited to look for known setup errors in
      # the captured stderr and override the generic "exited N — tail …"
      # flash with an actionable diagnostic. Returns nil for the
      # exit-zero (silent) case and for non-matching failures so
      # `Update.apply_subprocess_exited` keeps its existing default
      # flash behavior.
      def diagnose_subprocess_exit(msg)
        return nil if msg.exit_code.nil? || msg.exit_code.zero?

        diagnostic = Hive::Tui::Subprocess.diagnose_recent_failure(msg.verb)
        return nil if diagnostic.nil?

        [ @hive_model.with(flash: diagnostic, flash_set_at: Time.now), nil ]
      end

      # Scan a fresh snapshot for tasks whose `:error` marker came from
      # a signal kill (130 / 137 / 143) and clear the marker in the
      # background. Each folder is healed at most once per session
      # (`@healed_folders` dedup) so the loop never thrashes if the
      # background heal is slow or the marker re-appears for an
      # unrelated reason.
      #
      # The heal runs in a Ruby thread — `hive markers clear` is an
      # in-process subprocess via `run_quiet!` which captures
      # stdout/stderr cleanly without touching the alt-screen. The
      # next snapshot poll picks up the cleared marker and the row
      # re-classifies (typically back to "Ready for X" because the
      # agent's pre-kill state is preserved in the task folder).
      def auto_heal_kill_class_errors(snapshot)
        return if snapshot.nil?

        snapshot.rows.each do |row|
          next unless kill_class_error?(row)
          next unless register_heal_attempt(row.folder)

          spawn_heal_thread(row)
        end
      end

      def kill_class_error?(row)
        return false unless row.action_key == "error"

        attrs = row.attrs
        return false if attrs.nil?
        return false unless attrs["reason"] == "exit_code"

        KILL_CLASS_EXIT_CODES.include?(attrs["exit_code"].to_s)
      end

      # Time-bounded eviction window: a previous successful heal blocks
      # re-heals of the same folder for `HEAL_REPEAT_INTERVAL_SECONDS`,
      # then the slot becomes available again. Without the bound, a
      # later kill-class error on the same folder (theoretically: the
      # same folder/slug pair could be re-killed in the same session)
      # would never re-heal because the cache permanently held the
      # entry. F11 fix.
      HEAL_REPEAT_INTERVAL_SECONDS = 60

      # Atomic claim-or-skip on `@healed_folders`. Returns true when
      # this caller wins the slot (must spawn the heal); false when a
      # prior call claimed it within the last
      # HEAL_REPEAT_INTERVAL_SECONDS.
      def register_heal_attempt(folder)
        @healed_folders_mutex.synchronize do
          claimed_at = @healed_folders[folder]
          return false if claimed_at && (Time.now - claimed_at) <= HEAL_REPEAT_INTERVAL_SECONDS

          @healed_folders[folder] = Time.now
          true
        end
      end

      # On heal failure, evict the folder so the next snapshot's
      # `register_heal_attempt` succeeds and retries. Without this,
      # a transient `hive markers clear` failure would strand the
      # row in "Error" forever (the cache would block re-attempts).
      def evict_heal_attempt(folder)
        @healed_folders_mutex.synchronize { @healed_folders.delete(folder) }
      end

      # Override-able for tests so they can capture the heal
      # invocation without forking a real `hive markers clear`.
      # F8: tracks the spawned Thread on `@heal_threads` so
      # `kill_inflight_heals!` can reap stragglers at TUI exit; the
      # Thread prunes itself once the heal returns to bound the
      # tracking list under long sessions.
      def spawn_heal_thread(row)
        thread = Thread.new do
          heal_marker(row)
        ensure
          @healed_folders_mutex.synchronize { @heal_threads.delete(Thread.current) }
        end
        @healed_folders_mutex.synchronize { @heal_threads << thread }
        thread
      end

      # Reaping protocol for the App.run_charm ensure block. Two
      # phases share a single wall-clock deadline so a long-running
      # heal can't bottleneck the whole batch: phase 1 joins every
      # thread under one collective timeout (well-behaved heals
      # finish here); phase 2 force-kills stragglers and joins each
      # briefly to let their `ensure` block run. Snapshot/join is
      # done outside the mutex (Thread#join releases the GVL so
      # blocking under the lock would freeze the lifecycle); the
      # mutator path (`spawn_heal_thread`'s `ensure`) is still safe
      # to run against an already-empty list. Public because
      # App.run_charm calls it from outside the class on TUI
      # shutdown.
      JOIN_TIMEOUT_SECONDS = 2.0
      KILL_GRACE_SECONDS = 0.1

      public def kill_inflight_heals!
        threads = @healed_folders_mutex.synchronize { @heal_threads.dup }
        deadline = Time.now + JOIN_TIMEOUT_SECONDS
        threads.each do |t|
          remaining = deadline - Time.now
          break if remaining <= 0

          t.join(remaining)
        end
        threads.each do |t|
          next unless t.alive?

          t.kill
          t.join(KILL_GRACE_SECONDS)
        end
      end

      # Calls `hive markers clear` and converts any failure (non-zero
      # exit, exception) into a debug-log entry + cache eviction so
      # the next snapshot retries. Without the eviction, a single
      # transient failure would leave the row stuck in Error
      # indefinitely while `@healed_folders` blocked re-heals.
      #
      # `--match-attr exit_code=<observed>` ties the clear to the
      # specific kill-class marker we observed. If a concurrent
      # `hive run` writes a NEW `:error exit_code=1` (real failure)
      # between snapshot and heal, the match refuses, eviction fires,
      # and the next snapshot's auto-heal pass sees the real failure
      # instead of erasing it.
      def heal_marker(row)
        observed_exit = row.attrs && row.attrs["exit_code"]
        argv = [ "hive", "markers", "clear", row.folder, "--name", "ERROR" ]
        argv += [ "--match-attr", "exit_code=#{observed_exit}" ] if observed_exit
        exit_code, _out, err = Hive::Tui::Subprocess.run_quiet!(argv)
        return if exit_code.zero?

        Hive::Tui::Debug.log(
          "auto_heal",
          "clear failed for #{row.slug}: exit=#{exit_code} err=#{err.lines.first&.chomp.to_s[0, 120]}"
        )
        evict_heal_attempt(row.folder)
      rescue StandardError => e
        Hive::Tui::Debug.log("auto_heal", "failed for #{row.slug}: #{e.class.name}: #{e.message}")
        evict_heal_attempt(row.folder)
      end

      # Workflow verbs route by `Hive::Workflows.interactive?(verb)`:
      #
      #   * Non-interactive (default) → `Subprocess.dispatch_background`
      #     spawns the child in a separate pgroup with stdio captured
      #     to `SUBPROCESS_LOG_PATH`. The TUI render loop keeps going;
      #     multiple agents across multiple projects run concurrently.
      #     A reaper Thread sends `Messages::SubprocessExited` when
      #     each child exits, which surfaces as a flash.
      #
      #   * Interactive → `Subprocess.takeover_command` returns a
      #     `Bubbletea::SequenceCommand(exit_alt, exec, enter_alt)`.
      #     The runner exits alt-screen, runs the child synchronously
      #     with the user's tty (so stdin prompts work), and re-enters
      #     alt-screen on return. Blocks the TUI for the duration —
      #     same trade as the curses-era takeover, opt-in only when
      #     the verb genuinely needs stdin.
      #
      # An immediate flash ("running …") fires synchronously in BOTH
      # paths so the user gets visual confirmation their keypress did
      # something. The flash is overwritten by SubprocessExited's
      # success/failure flash on completion.
      def dispatch_command(message)
        verb = message.verb || message.argv[1] || "verb"
        slug = message.argv[2] || ""

        cmd = if verb_interactive?(verb)
                Hive::Tui::Subprocess.takeover_command(message.argv, dispatch: @dispatch)
        else
                Hive::Tui::Subprocess.dispatch_background(message.argv, dispatch: @dispatch)
                nil
        end

        flash_text = slug.empty? ? "running `hive #{verb}`…" : "running `hive #{verb} #{slug}`…"
        [ @hive_model.with(flash: flash_text, flash_set_at: Time.now), cmd ]
      end

      # Indirection through an instance method (rather than calling
      # `Hive::Workflows.interactive?` directly) so tests can override
      # the predicate per-instance with `define_singleton_method`
      # instead of mutating the module's singleton class. Keeps the
      # test seam narrow and removes ordering/concurrency risk
      # between tests that touch the same global.
      def verb_interactive?(verb)
        Hive::Workflows.interactive?(verb)
      end

      # Synchronous I/O: open the review file, build a TriageState,
      # flip mode. If the file is missing (concurrent archive) we flash
      # and stay in grid mode rather than entering an empty triage view.
      def open_findings(row)
        task = Hive::Task.new(row.folder)
        review_path = Hive::Findings.review_path_for(task)

        document = Hive::Findings::Document.new(review_path)
        state = Hive::Tui::TriageState.new(
          slug: row.slug, folder: row.folder,
          findings: document.findings, review_path: review_path
        )
        [ @hive_model.with(mode: :triage, triage_state: state), nil ]
      rescue Hive::NoReviewFile, Hive::InvalidTaskPath, Errno::ENOENT
        [ flashed("no review file for #{row.slug}"), nil ]
      end

      # Open the most recent log file under the row's `.hive/logs/`,
      # build a Tail, flip mode. Race-tolerant: if the file disappears
      # between resolve and open, flash instead of crashing.
      #
      # `FileResolver.latest` raises `Hive::NoLogFiles` (not nil) when
      # the dir has no `*.log` entries — must be in the rescue list or
      # the exception unwinds out of `Bubbletea::Runner` and tears the
      # TUI down. Common on tasks that haven't run any agent yet (the
      # `logs/` dir is created lazily by `Hive::Agent`).
      def open_log_tail(row)
        task = Hive::Task.new(row.folder)
        log_dir = File.join(task.folder, "logs")
        log_path = Hive::Tui::LogTail::FileResolver.latest(log_dir)

        tail = Hive::Tui::LogTail::Tail.new(log_path)
        tail.open!
        wrapper = LogTailContext.new(tail: tail, claude_pid_alive: row.claude_pid_alive)
        [ @hive_model.with(mode: :log_tail, tail_state: wrapper), log_tail_poll_cmd ]
      rescue Hive::NoLogFiles
        [ flashed("no logs yet for #{row.slug}"), nil ]
      rescue Hive::InvalidTaskPath, Errno::ENOENT, Errno::EACCES
        [ flashed("log file gone"), nil ]
      end

      # 0.5s tick: long enough that a slow agent log doesn't cost a
      # poll per frame, short enough that fresh bytes feel live.
      # Symmetric with the curses path's per-frame poll cadence.
      LOG_TAIL_POLL_INTERVAL = 0.5

      # @api private
      def log_tail_poll_cmd
        Bubbletea.tick(LOG_TAIL_POLL_INTERVAL) { Hive::Tui::Messages::LOG_TAIL_POLL }
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
