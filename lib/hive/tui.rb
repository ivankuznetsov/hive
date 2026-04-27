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
      raise Hive::Error, "hive tui requires a terminal" unless $stdout.tty?

      require "curses"
      require "hive/tui/state_source"
      require "hive/tui/grid_state"
      require "hive/tui/render/grid"
      require "hive/tui/render/palette"
      require "hive/tui/render/filter_prompt"
      require "hive/tui/key_map"
      require "hive/tui/subprocess"

      run_loop
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
      end
    end

    def self.render_dispatch_loop(state_source, grid_state, grid)
      loop do
        snapshot = state_source.current
        grid.draw(snapshot, grid_state) if snapshot
        ch = Curses.getch
        next if ch.nil?

        key = translate_key(ch)
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
      when :help then grid_state.flash!("help overlay not yet wired (U8)")
      when :open_findings then run_triage(payload, grid_state)
      when :open_log_tail, :open_editor
        grid_state.flash!("Enter actions land in U7")
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
        renderer.draw(triage_state, slug: row.slug, review_path: review_path)
        ch = Curses.getch
        next if ch.nil?

        action = Hive::Tui::KeyMap.dispatch(mode: :triage, key: translate_key(ch), row: row)
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

    def self.run_toggle(triage_state, renderer, review_path)
      finding = triage_state.current_finding
      return unless finding

      argv = triage_state.toggle_command(finding)
      exit_status, _out, err = Hive::Tui::Subprocess.run_quiet!(argv)
      reload_or_flash(triage_state, renderer, review_path, exit_status: exit_status, err: err)
    end

    def self.run_bulk(triage_state, renderer, review_path, direction)
      argv = triage_state.bulk_command(direction)
      exit_status, _out, err = Hive::Tui::Subprocess.run_quiet!(argv)
      reload_or_flash(triage_state, renderer, review_path, exit_status: exit_status, err: err)
    end

    # On non-zero exit we surface stderr in the status line and keep the
    # cursor put. On success, reload the document so a concurrent
    # rewrite (review re-run) can't leave the state pointing at stale
    # IDs; relocate-cursor's `:reset` indicator triggers a flash so the
    # user sees why the highlight jumped.
    def self.reload_or_flash(triage_state, renderer, review_path, exit_status:, err:)
      if exit_status != 0
        renderer.flash!(err.to_s.lines.first&.strip || "subprocess failed (exit #{exit_status})")
        return
      end

      new_doc = Hive::Findings::Document.new(review_path)
      indicator = triage_state.relocate_cursor(new_doc.findings)
      renderer.flash!("review file changed; cursor reset") if indicator == :reset
    end

    # Curses returns Integer codes for special keys and a single-char
    # String for printable input. Map to the surface KeyMap expects:
    # `:key_*` Symbols for navigation, single-char Strings for the rest.
    def self.translate_key(ch)
      return ch if ch.is_a?(String)
      return :unknown unless ch.is_a?(Integer)

      case ch
      when Curses::KEY_DOWN then :key_down
      when Curses::KEY_UP then :key_up
      when Curses::KEY_ENTER, 10, 13 then :key_enter
      when 27 then :key_escape
      else printable_or_unknown(ch)
      end
    end

    # Restrict raw integer-to-chr conversion to the printable ASCII band
    # so unmapped function keys / escape sequences don't surface as
    # garbage bytes that KeyMap then routes as no-ops.
    def self.printable_or_unknown(ch)
      return ch.chr if ch.between?(32, 126)

      :unknown
    end

    def self.handle_filter_prompt(grid_state, snapshot)
      result = Hive::Tui::Render::FilterPrompt.new.read(initial: grid_state.filter)
      case result[:action]
      when :commit then grid_state.set_filter(result[:value], snapshot)
      when :clear then grid_state.set_filter(nil, snapshot)
      end
    end
  end
end
