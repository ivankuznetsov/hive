require "hive"

module Hive
  # Top-level TUI module: a curses-based, full-screen, modal dashboard
  # that polls `Hive::Commands::Status#json_payload` at ~1 Hz, renders
  # every active task across registered projects grouped by action label,
  # and dispatches workflow verbs as fresh subprocesses on single-key
  # keystrokes.
  #
  # The TUI is a thin overlay on the existing CLI semantics: it consumes
  # the same JSON `hive status` emits, classifies rows via
  # `Hive::TaskAction`, and shells out for every state mutation. It
  # never writes markers directly and never touches state files outside
  # the existing command surface.
  #
  # MRI-only: the data layer relies on MRI 3.4's GVL for safe
  # cross-thread reads of `@current` snapshots without a Mutex.
  # JRuby/TruffleRuby would need a synchronisation upgrade.
  module Tui
    # Entry point invoked by `Hive::CLI#tui`. Boots curses, spins up the
    # background poller, and runs the render+dispatch loop until `q`.
    # Curses input timeout is 100ms so a fresh snapshot from the poller
    # repaints within ~one frame of arriving even when the user is idle.
    def self.run
      raise Hive::Error, "hive tui requires MRI Ruby (got #{RUBY_ENGINE})" unless RUBY_ENGINE == "ruby"
      # Boundary parity with `hive tui --json`: both reject with USAGE (64) so a
      # non-tty CI invocation and a misuse `--json` flag share the exit-code surface.
      raise Hive::InvalidTaskPath, "hive tui requires a terminal" unless $stdout.tty?

      require "curses"
      require "hive/tui/state_source"
      require "hive/tui/grid_state"
      require "hive/tui/render/grid"
      require "hive/tui/render/palette"
      require "hive/tui/render/filter_prompt"
      require "hive/tui/key_map"
      require "hive/tui/key_map/curses_keys"
      require "hive/tui/subprocess"
      require "hive/tui/subprocess_registry"

      install_terminal_safety_hooks
      run_loop
    end

    # Called BEFORE the first `Curses.init_screen` so a crash during
    # init still restores the terminal. Idempotent — guarded by
    # `@hooks_installed` so repeated `Hive::Tui.run` invocations from
    # tests (or from daemons that respawn the loop) don't stack
    # at_exit callbacks. The SIGHUP trap is also installed here; it
    # flips a flag the render loop checks between frames so curses
    # API calls are NEVER made from the trap context.
    def self.install_terminal_safety_hooks
      return if @hooks_installed

      @terminate_requested = false
      at_exit do
        begin
          Curses.close_screen
        rescue StandardError
          nil
        end
        Hive::Tui::SubprocessRegistry.kill_inflight!
      end

      @prev_hup = trap("HUP") { @terminate_requested = true }
      @hooks_installed = true
    end

    # Inverse of `install_terminal_safety_hooks`: puts the SIGHUP trap
    # back to whatever the parent process had before `Hive::Tui.run`
    # entered. Called from `run_loop`'s `ensure` so a clean exit
    # doesn't leak our trap into the parent shell. The at_exit
    # callback can't be unregistered, but it short-circuits when the
    # `@hooks_installed` guard is false on a subsequent run.
    def self.restore_terminal_safety_hooks
      return unless @hooks_installed

      trap("HUP", @prev_hup || "DEFAULT")
      @hooks_installed = false
      @prev_hup = nil
    end

    # Test seam — exposes whether the boot guard already installed the
    # at_exit + SIGHUP hooks. The U9 integration test asserts this is
    # true after `Hive::Tui.run` boot, even before `Curses.init_screen`
    # would have run.
    def self.atexit_registered?
      @hooks_installed == true
    end

    # Test/support helpers for the SIGHUP path. The render loop polls
    # `terminate_requested?` between frames; tests use the setter to
    # exercise the cleanup path without sending a real signal.
    def self.terminate_requested?
      @terminate_requested == true
    end

    def self.request_terminate!
      @terminate_requested = true
    end

    def self.run_loop
      state_source = Hive::Tui::StateSource.new
      state_source.start
      grid_state = Hive::Tui::GridState.new
      grid = Hive::Tui::Render::Grid.new

      Curses.init_screen
      begin
        Curses.cbreak
        Curses.noecho
        Curses.stdscr.keypad(true)
        Curses.curs_set(0)
        Hive::Tui::Render::Palette.init!
        Curses.timeout = 100

        render_dispatch_loop(state_source, grid_state, grid)
      ensure
        state_source.stop
        Curses.close_screen
        restore_terminal_safety_hooks
      end
    end

    def self.render_dispatch_loop(state_source, grid_state, grid)
      loop do
        break if terminate_requested?

        snapshot = state_source.current
        grid.draw(snapshot, grid_state, state_source: state_source) if snapshot
        ch = Curses.getch
        next if ch.nil?

        # Resize is handled at the loop level — clear and let the next
        # iteration repaint against the new terminal dimensions. Per
        # KTD-5 we DO NOT install a Ruby SIGWINCH trap; ncurses' default
        # handler injects KEY_RESIZE into the next getch instead.
        if ch.is_a?(Integer) && ch == Curses::KEY_RESIZE
          Curses.clear
          next
        end

        key = Hive::Tui::KeyMap::CursesKeys.translate(ch)
        action = Hive::Tui::KeyMap.dispatch(
          mode: :grid,
          key: key,
          row: snapshot ? grid_state.at_cursor(snapshot) : nil
        )
        break if handle_action(action, grid_state, snapshot) == :quit
      end
    end

    # Returns :quit to break the loop; nil otherwise. Centralised so the
    # main loop's body stays under Metrics/MethodLength.
    def self.handle_action(action, grid_state, snapshot)
      verb, payload = action
      case verb
      when :quit then return :quit
      when :cursor_down then grid_state.move_cursor_down(snapshot) if snapshot
      when :cursor_up then grid_state.move_cursor_up(snapshot) if snapshot
      when :project_scope then grid_state.set_scope(payload, snapshot) if snapshot
      when :filter then handle_filter_prompt(grid_state, snapshot) if snapshot
      when :flash then grid_state.flash!(payload)
      when :dispatch_command then Hive::Tui::Subprocess.takeover!(payload)
      when :help then show_help_overlay
      when :open_findings then run_triage(payload, grid_state)
      when :open_log_tail then run_log_tail(payload, grid_state)
      when :open_editor then run_editor(payload, grid_state)
      end
      nil
    end

    # Triage subloop — runs until Esc/back. Loads the latest review file,
    # constructs a TriageState + Render::Triage, then dispatches Space /
    # `d` / `a` / `r` per KeyMap's `:triage` mode. Space toggles use
    # `Subprocess.run_quiet!` (no screen tear-down per KTD-4); `d` does a
    # full takeover so the implementation pass streams to the user's tty.
    def self.run_triage(row, grid_state)
      require "hive/findings"
      require "hive/task"
      require "hive/tui/triage_state"
      require "hive/tui/render/triage"

      task = Hive::Task.new(row.folder)
      review_path = resolve_review_path(task, grid_state)
      return unless review_path

      document = Hive::Findings::Document.new(review_path)
      triage_state = Hive::Tui::TriageState.new(slug: row.slug, findings: document.findings)
      renderer = Hive::Tui::Render::Triage.new

      triage_loop(triage_state, renderer, row, review_path)
    end

    def self.resolve_review_path(task, grid_state)
      Hive::Findings.review_path_for(task)
    rescue Hive::NoReviewFile => e
      grid_state.flash!(e.message)
      nil
    end

    def self.triage_loop(triage_state, renderer, row, review_path)
      loop do
        # SIGHUP between frames must collapse subloops promptly so the
        # render loop's terminate check exits cleanly.
        return if terminate_requested?

        renderer.draw(triage_state, slug: row.slug, review_path: review_path)
        ch = Curses.getch
        next if ch.nil?

        action = Hive::Tui::KeyMap.dispatch(mode: :triage, key: Hive::Tui::KeyMap::CursesKeys.translate(ch), row: row)
        result = handle_triage_action(action, triage_state, renderer, review_path)
        return if result == :back
      end
    end

    def self.handle_triage_action(action, triage_state, renderer, review_path)
      verb, _payload = action
      case verb
      when :back then :back
      when :cursor_down then triage_state.cursor_down
      when :cursor_up then triage_state.cursor_up
      when :toggle_finding then run_toggle(triage_state, renderer, review_path)
      when :dispatch_command then takeover_and_return(triage_state, action.last)
      when :bulk_accept then run_bulk(triage_state, renderer, review_path, :accept)
      when :bulk_reject then run_bulk(triage_state, renderer, review_path, :reject)
      end
    end

    # `d` synthesises `hive develop --from 4-execute`; once the pass
    # finishes, the action label moves off `review_findings` so we
    # return to grid rather than re-rendering a stale triage view.
    def self.takeover_and_return(_triage_state, argv)
      Hive::Tui::Subprocess.takeover!(argv)
      :back
    end

    # Returns the result of `reload_or_flash` (nil or :back) so the
    # vanished-review-file case can propagate upward to the triage loop.
    def self.run_toggle(triage_state, renderer, review_path)
      finding = triage_state.current_finding
      return unless finding

      argv = triage_state.toggle_command(finding)
      announce_subprocess(renderer, argv)
      exit_status, _out, err = Hive::Tui::Subprocess.run_quiet!(argv)
      reload_or_flash(triage_state, renderer, review_path, exit_status: exit_status, err: err)
    end

    def self.run_bulk(triage_state, renderer, review_path, direction)
      argv = triage_state.bulk_command(direction)
      announce_subprocess(renderer, argv)
      exit_status, _out, err = Hive::Tui::Subprocess.run_quiet!(argv)
      reload_or_flash(triage_state, renderer, review_path, exit_status: exit_status, err: err)
    end

    # Paint an inline "running…" status on the bottom row before
    # run_quiet! blocks the render thread for ~150ms+ of subprocess
    # startup. We bypass the renderer's flash buffer (which only
    # repaints on the next draw call — too late) and write directly
    # to Curses so the feedback appears synchronously, before the
    # blocking spawn. KTD-4 accepted the per-keystroke spawn cost
    # but didn't address the perceived-frozen gap; this closes it.
    def self.announce_subprocess(_renderer, argv)
      return unless defined?(Curses) && Curses.respond_to?(:refresh)

      verb = argv[1].to_s
      Curses.setpos(Curses.lines - 1, 0)
      Curses.clrtoeol
      Curses.addstr("running #{verb}…")
      Curses.refresh
    end

    # On non-zero exit we surface stderr in the status line and keep the
    # cursor put. On success, reload the document so a concurrent
    # rewrite (review re-run) can't leave the state pointing at stale
    # IDs; relocate-cursor's `:reset` indicator triggers a flash so the
    # user sees why the highlight jumped. If the review file vanished
    # mid-session (concurrent archive / rerun) we return :back so the
    # triage loop drops back to grid instead of crashing on the reload.
    def self.reload_or_flash(triage_state, renderer, review_path, exit_status:, err:)
      if exit_status != 0
        renderer.flash!(err.to_s.lines.first&.strip || "subprocess failed (exit #{exit_status})")
        return
      end

      new_doc = Hive::Findings::Document.new(review_path)
      indicator = triage_state.relocate_cursor(new_doc.findings)
      renderer.flash!("review file changed; cursor reset") if indicator == :reset
    rescue Hive::NoReviewFile
      renderer.flash!("review file vanished; returning to grid")
      :back
    end

    # `?` overlay — paint the keybinding modal and block on a single
    # `getch` to dismiss. The render loop repaints the underlying grid
    # on the next iteration so we don't have to remember the prior
    # frame here.
    def self.show_help_overlay
      require "hive/tui/render/help_overlay"
      Hive::Tui::Render::HelpOverlay.new.show
    end

    # Spawn $EDITOR (with VISUAL fallback, then `vi`) on the row's
    # state file via a full-screen takeover so vim/emacs/nano gets a
    # cooked-mode tty. Shellsplit so a configured `EDITOR="vim -p"`
    # works without re-introducing a shell layer.
    def self.run_editor(row, grid_state)
      require "shellwords"
      editor = ENV["EDITOR"] || ENV["VISUAL"] || "vi"
      if editor.to_s.strip.empty?
        grid_state.flash!("$EDITOR not set; cannot open #{File.basename(row.state_file.to_s)}")
        return
      end

      argv = Shellwords.split(editor) + [ row.state_file ]
      exit_status = Hive::Tui::Subprocess.takeover!(argv)
      grid_state.flash!("editor exited #{exit_status}") if exit_status != 0
    end

    # Log-tail subloop — open the latest `<state>/logs/<slug>/*.log`
    # for the highlighted `agent_running` row and tail it via
    # non-blocking reads driven by the render loop's 100ms input
    # timeout. q/Esc returns to the grid. If no log file exists yet
    # (common race between the snapshot showing `agent_running` and
    # the agent flushing its first byte), flash a friendly message
    # and stay in the grid.
    def self.run_log_tail(row, grid_state)
      require "hive/task"
      require "hive/tui/log_tail"
      require "hive/tui/render/log_tail"

      task = Hive::Task.new(row.folder)
      log_path = resolve_log_path(task, grid_state)
      return unless log_path

      tail = Hive::Tui::LogTail::Tail.new(log_path)
      # Race with log rotation/permission flap between FileResolver.latest
      # and the open syscall — flash + return rather than letting the
      # raw Errno escape and crash the TUI loop.
      begin
        tail.open!
      rescue Errno::ENOENT, Errno::EACCES => e
        grid_state.flash!("log file unavailable: #{e.class.name.split('::').last}")
        return
      end
      renderer = Hive::Tui::Render::LogTail.new

      begin
        log_tail_loop(tail, renderer, row, log_path)
      ensure
        tail.close!
      end
    end

    def self.resolve_log_path(task, grid_state)
      Hive::Tui::LogTail::FileResolver.latest(task.log_dir)
    rescue Hive::NoLogFiles
      grid_state.flash!("(no log files yet — agent may not have written any output)")
      nil
    end

    def self.log_tail_loop(tail, renderer, row, log_path)
      loop do
        return if terminate_requested?

        tail.poll!
        renderer.draw(tail, Curses.lines, log_path: log_path,
                                          claude_pid_alive: row.claude_pid_alive)
        ch = Curses.getch
        next if ch.nil?

        action = Hive::Tui::KeyMap.dispatch(mode: :log_tail, key: Hive::Tui::KeyMap::CursesKeys.translate(ch), row: row)
        return if action.first == :back
      end
    end

    def self.handle_filter_prompt(grid_state, snapshot)
      result = Hive::Tui::Render::FilterPrompt.new.read(initial: grid_state.filter)
      case result[:action]
      when :commit then grid_state.set_filter(result[:value], snapshot)
      when :clear then grid_state.set_filter(nil, snapshot)
      end
    end

    # Public surface stays narrow: `run` (entry point), `atexit_registered?`,
    # `terminate_requested?`, `request_terminate!`. Everything else is
    # implementation-private so the API agents and tests can rely on stays
    # explicit and refactor-safe.
    private_class_method :install_terminal_safety_hooks, :restore_terminal_safety_hooks,
                         :run_loop, :render_dispatch_loop,
                         :handle_action, :run_triage, :resolve_review_path, :triage_loop,
                         :handle_triage_action, :takeover_and_return, :run_toggle, :run_bulk,
                         :reload_or_flash, :announce_subprocess,
                         :show_help_overlay, :run_editor,
                         :run_log_tail, :resolve_log_path,
                         :log_tail_loop,
                         :handle_filter_prompt
  end
end
