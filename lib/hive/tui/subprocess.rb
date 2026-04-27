require "open3"
require "io/console"
require "bubbletea"
require "hive/tui/debug"
require "hive/tui/messages"
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

      # Charm path: returns a `Bubbletea::ExecCommand` that, when run by the
      # framework's runner, spawns argv with pgroup forwarding, waits, and
      # dispatches a `Messages::SubprocessExited(verb:, exit_code:)` back into
      # the loop via `dispatch.call(message)`.
      #
      # The framework owns suspend/resume of raw mode, cursor, and input
      # reader (see `Bubbletea::Runner#exec_process`) — that's why this path
      # has no curses dance and no termios save/restore. The curses
      # `takeover!` retains both because the curses backend manages its own
      # alt-screen lifecycle.
      #
      # The `dispatch:` parameter is the seam for runner injection. App's
      # charm boot will wire `dispatch: runner.method(:send)` (Bubbletea's
      # Runner overrides `Object#send` to enqueue messages onto the loop's
      # input stream). Tests pass a plain capture lambda. We can't use the
      # built-in `message:` argument of the takeover builder because the
      # exit code isn't known at command-construction time — closure-capture
      # is the only path that surfaces the actual exit code.
      #
      # Verb is cached at argv[1] at construction time so SubprocessExited
      # carries the verb name even if argv is mutated downstream — same
      # contract as `Messages::DispatchCommand.verb`.
      def takeover_command(argv, dispatch:)
        verb = argv[1]
        callable = lambda do
          exit_code = run_takeover_child(argv)
          dispatch.call(Messages::SubprocessExited.new(verb: verb, exit_code: exit_code))
        end
        Bubbletea.public_send(:exec, callable)
      end

      # Extracted spawn-and-wait core shared between the curses `takeover!`
      # path and the charm `takeover_command` callable. Returns the same
      # Integer exit shape: 0..255 for clean exits, 128+signo for signal
      # kills, COMMAND_NOT_FOUND_EXIT (127) for missing binary.
      def run_takeover_child(argv)
        Hive::Tui::Debug.log("takeover_command", "argv=#{argv.inspect}")
        prev_int, prev_term = install_pgid_forwarding_traps
        begin
          pid = Process.spawn(*argv, pgroup: true)
          register_real_pgid(pid)
          Hive::Tui::Debug.log("takeover_command", "pid=#{pid} pgid=#{SubprocessRegistry.current.inspect}")
          _, status = Process.wait2(pid)
          translate_status(status)
        rescue Errno::ENOENT, Errno::EACCES => e
          Hive::Tui::Debug.log("takeover_command", "errno=#{e.class.name}: #{e.message}")
          COMMAND_NOT_FOUND_EXIT
        ensure
          SubprocessRegistry.clear
          restore_traps(prev_int, prev_term)
        end
      end

      def takeover!(argv)
        Hive::Tui::Debug.log("takeover", "argv=#{argv.inspect}")
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
            Hive::Tui::Debug.log("takeover", "spawning")
            pid = Process.spawn(*argv, pgroup: true)
            register_real_pgid(pid)
            Hive::Tui::Debug.log("takeover", "pid=#{pid} pgid=#{SubprocessRegistry.current.inspect}")
            _, status = Process.wait2(pid)
            exit_code = translate_status(status)
            Hive::Tui::Debug.log("takeover", "exit=#{exit_code} status=#{status.inspect}")
          rescue Errno::ENOENT, Errno::EACCES => e
            exit_code = COMMAND_NOT_FOUND_EXIT
            Hive::Tui::Debug.log("takeover", "errno=#{e.class.name}: #{e.message}")
          ensure
            SubprocessRegistry.clear
            restore_traps(prev_int, prev_term)
            restore_termios(pre_termios)
            Hive::Tui::Debug.log("takeover", "ensure done; about to restore_curses_state")
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
        Hive::Tui::Debug.log("run_quiet", "argv=#{argv.inspect}")
        prev_int, prev_term = install_pgid_forwarding_traps
        begin
          out, err, status = Open3.capture3(*argv, pgroup: true)
          exit_code = status.exitstatus || -1
          Hive::Tui::Debug.log("run_quiet", "exit=#{exit_code} out_bytes=#{out.bytesize} err_bytes=#{err.bytesize}")
          [ exit_code, out, err ]
        rescue Errno::ENOENT, Errno::EACCES => e
          Hive::Tui::Debug.log("run_quiet", "errno=#{e.class.name}: #{e.message}")
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

        Hive::Tui::Debug.log("curses", "restore: reset_prog_mode → clear → refresh")
        begin
          Curses.reset_prog_mode
          Curses.clear if Curses.respond_to?(:clear)
          Curses.refresh if Curses.respond_to?(:refresh)
          Hive::Tui::Debug.log("curses", "restore: done")
        rescue StandardError => e
          Hive::Tui::Debug.log("curses", "restore: #{e.class.name}: #{e.message}")
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
    end
  end
end
