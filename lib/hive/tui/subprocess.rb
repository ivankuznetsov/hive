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
      def takeover!(argv)
        with_curses_suspended do
          pre_termios = save_termios
          prev_int, prev_term = install_pgid_forwarding_traps
          begin
            pid = Process.spawn(*argv, pgroup: true)
            register_real_pgid(pid)
            _, status = Process.wait2(pid)
            translate_status(status)
          ensure
            SubprocessRegistry.clear
            restore_traps(prev_int, prev_term)
            restore_termios(pre_termios)
          end
        end
      end

      # Returns [exit_status, stdout, stderr]. `Open3.capture3` waits
      # internally so we never see the child's pgid; we still register a
      # placeholder so a SIGHUP during the call observes a non-nil slot
      # and the U9 hook treats it as "spawn in progress, no-op kill".
      def run_quiet!(argv)
        SubprocessRegistry.register_placeholder
        prev_int, prev_term = install_pgid_forwarding_traps
        begin
          out, err, status = Open3.capture3(*argv, pgroup: true)
          [ status.exitstatus || -1, out, err ]
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

      def restore_curses_state
        return unless defined?(Curses) && Curses.respond_to?(:reset_prog_mode)

        begin
          Curses.reset_prog_mode
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
    end
  end
end
