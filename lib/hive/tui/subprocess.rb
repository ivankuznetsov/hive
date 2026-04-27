require "open3"
require "io/console"
require "hive/tui/subprocess_registry"

module Hive
  module Tui
    # Two ways to run a child from inside the TUI without corrupting the
    # parent's terminal:
    #
    #   * `takeover!(argv)` — the child gets the real tty (interactive verbs
    #     like `hive develop` need this). Curses is suspended, termios is
    #     saved, the child runs in its own pgroup so SIGINT/SIGTERM can be
    #     forwarded to the group rather than just the leader, and on return
    #     curses + termios are restored.
    #   * `run_quiet!(argv)` — the child is non-interactive; stdio is piped
    #     and captured. No curses dance.
    #
    # Both manage SubprocessRegistry around the spawn so the SIGHUP cleanup
    # hook in U9 can kill the in-flight child group on shutdown, and both
    # restore the parent's INT/TERM trap handlers in `ensure` regardless of
    # exit shape (clean, signal, exception). The pgid+trap idiom mirrors
    # `Hive::Agent#spawn_and_wait` (lib/hive/agent.rb:99-117).
    #
    # `Curses` is NOT required at the top of this file: tests run without
    # initialising curses, and U9 will require it lazily once the render
    # loop boots. Every curses call is guarded by `defined?(Curses)`.
    module Subprocess
      module_function

      # Returns Integer exit status. For signal-killed children, returns
      # `128 + signo` (POSIX shell convention) so callers see a non-zero,
      # non-overlapping value instead of nil.
      # POSIX shells use 127 for "command not found"; reuse it so the TUI
      # caller can flash a stable status without ambiguating between a
      # missing binary and an explicit child exit code.
      COMMAND_NOT_FOUND_EXIT = 127

      def takeover!(argv)
        # Capture termios BEFORE curses' def_prog_mode runs (inside
        # with_curses_suspended). The captured baseline must be the
        # parent's pre-curses tty state so restore_termios can hand
        # the child a clean slate; capturing AFTER def_prog_mode
        # would freeze a curses-flavoured termios that ttys then
        # restore on return — see KTD-3 in the plan.
        pre_termios = save_termios
        with_curses_suspended do
          prev_int, prev_term = install_pgid_forwarding_traps
          exit_code = nil
          begin
            pid = Process.spawn(*argv, pgroup: true)
            register_real_pgid(pid)
            _, status = Process.wait2(pid)
            exit_code = translate_status(status)
          rescue Errno::ENOENT, Errno::EACCES
            exit_code = COMMAND_NOT_FOUND_EXIT
            warn_command_not_found(argv)
          ensure
            SubprocessRegistry.clear
            restore_traps(prev_int, prev_term)
            restore_termios(pre_termios)
            # Pause when the child failed so the user can actually read
            # its error output before `restore_curses_state`'s clear
            # wipes the screen. Successful exits return promptly; the
            # render loop's clearing happens immediately after.
            pause_for_acknowledgement(exit_code, argv) if exit_code && exit_code != 0
          end
          exit_code
        end
      end

      # Returns [exit_status, stdout, stderr]. `Open3.capture3` manages
      # the child internally; we have no pgid to track. The placeholder
      # registration that pairs with the SIGHUP cleanup hook happens
      # inside `install_pgid_forwarding_traps` — registering again here
      # would be a redundant double-write to the same slot.
      def run_quiet!(argv)
        prev_int, prev_term = install_pgid_forwarding_traps
        begin
          out, err, status = Open3.capture3(*argv, pgroup: true)
          [ status.exitstatus || -1, out, err ]
        rescue Errno::ENOENT, Errno::EACCES
          [ COMMAND_NOT_FOUND_EXIT, "", "command not found: #{argv.first}" ]
        ensure
          SubprocessRegistry.clear
          restore_traps(prev_int, prev_term)
        end
      end

      # --- private helpers ---------------------------------------------------

      # Curses may not be loaded in tests; def_prog_mode/endwin/reset_prog_mode
      # are skipped entirely in that case. Curses::Error is rescued for the
      # "loaded but not initialised" case (e.g. unit-test boot).
      def with_curses_suspended
        save_curses_state
        end_curses
        begin
          yield
        ensure
          restore_curses_state
        end
      end

      def save_curses_state
        return unless defined?(Curses) && Curses.respond_to?(:def_prog_mode)

        begin
          Curses.def_prog_mode
        rescue StandardError
          # Curses::Error or any subclass — only meaningful when curses is
          # initialised. Boot/test contexts where the screen isn't up are fine.
          nil
        end
      end

      def end_curses
        return unless defined?(Curses) && Curses.respond_to?(:endwin)

        begin
          Curses.endwin
        rescue StandardError
          nil
        end
      end

      # After the child writes to the inherited terminal and exits,
      # ncurses' internal screen buffer is now stale relative to the
      # real terminal — `refresh` alone would only emit the diff
      # against the old buffer (= nothing), leaving subprocess output
      # painted in any rows the next render doesn't fully overwrite.
      # `Curses.clear` sets the clearok flag AND erases the internal
      # buffer so the next refresh emits a real clear-screen escape,
      # giving the next `Render::Grid#draw` a blank canvas.
      def restore_curses_state
        return unless defined?(Curses) && Curses.respond_to?(:reset_prog_mode)

        begin
          Curses.reset_prog_mode
          Curses.clear if Curses.respond_to?(:clear)
          Curses.refresh if Curses.respond_to?(:refresh)
        rescue StandardError
          nil
        end
      end

      # IO.console returns nil under nohup / no controlling tty. NoMethodError
      # also covers the "method not exposed by this Ruby build" case.
      def save_termios
        console = IO.console
        return nil unless console

        begin
          console.tcgetattr
        rescue Errno::ENOTTY, NoMethodError
          nil
        end
      end

      def restore_termios(pre)
        return unless pre

        console = IO.console
        return unless console

        begin
          console.tcsetattr(IO::TCSADRAIN, pre)
        rescue Errno::ENOTTY, NoMethodError
          nil
        end
      end

      # Trap blocks read the current pgid out of the registry so they
      # always forward to the live child even if the slot transitions
      # placeholder -> Integer mid-spawn. Trap returns the previous handler
      # which we hand back so `ensure` can restore it.
      def install_pgid_forwarding_traps
        SubprocessRegistry.register_placeholder
        prev_int = trap("INT") { forward_signal_to_inflight("INT") }
        prev_term = trap("TERM") { forward_signal_to_inflight("TERM") }
        [ prev_int, prev_term ]
      end

      def forward_signal_to_inflight(sig)
        pgid = SubprocessRegistry.current
        return unless pgid.is_a?(Integer)

        begin
          Process.kill(sig, -pgid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end

      def restore_traps(prev_int, prev_term)
        trap("INT", prev_int || "DEFAULT")
        trap("TERM", prev_term || "DEFAULT")
      end

      # Mirrors Hive::Agent#spawn_and_wait: ESRCH means the child died
      # before getpgid could observe it, in which case the pid is its own
      # process-group leader by virtue of pgroup: true.
      def register_real_pgid(pid)
        pgid = begin
          Process.getpgid(pid)
        rescue Errno::ESRCH
          pid
        end
        SubprocessRegistry.register(pgid)
      end

      # POSIX-shell convention for signal exits keeps the return type a
      # plain Integer the caller can compare against without unwrapping a
      # Status object.
      def translate_status(status)
        return status.exitstatus if status.exitstatus
        return 128 + status.termsig if status.signaled?

        -1
      end

      # Curses is suspended at this point and termios is back in cooked
      # mode, so a regular `gets` reads one line from the user's
      # terminal. Without this pause the next `restore_curses_state`
      # call clears the screen the moment takeover! returns, wiping
      # any error message the child wrote (e.g. `hive pr` exit 4
      # "cannot advance ..."). The user would then see nothing happen.
      def pause_for_acknowledgement(exit_code, argv)
        return unless $stdin.tty? && $stderr.tty?

        verb = argv[1] || argv.first
        $stderr.puts
        $stderr.puts "[hive tui] `#{verb}` exited #{exit_code} — press Enter to return to grid..."
        $stderr.flush
        begin
          $stdin.gets
        rescue StandardError
          nil
        end
      end

      # ENOENT means the binary at argv[0] could not be exec'd. The
      # child never wrote anything, so without this surface line the
      # user sees no output at all between curses-down and the
      # acknowledgement prompt.
      def warn_command_not_found(argv)
        $stderr.puts "[hive tui] command not found: #{argv.first}" if $stderr.tty?
      end
    end
  end
end
