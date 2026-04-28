require "open3"
require "tmpdir"
require "bubbletea"
require "hive/tui/debug"
require "hive/tui/messages"
require "hive/tui/subprocess_registry"

module Hive
  module Tui
    # Two ways to run a child from inside the TUI:
    #
    #   * `takeover_command(argv, dispatch:)` — interactive verbs (`hive
    #     develop`, `hive plan`, etc.) need the real tty. Returns a
    #     `Bubbletea::ExecCommand` the runner executes inside its own
    #     suspend window (raw mode disabled, cursor shown, input reader
    #     stopped). The callable spawns argv with `pgroup: true` so
    #     INT/TERM forward cleanly, waits for the child, and dispatches
    #     a `Messages::SubprocessExited(verb:, exit_code:)` back into
    #     the loop via the supplied `dispatch` lambda.
    #   * `run_quiet!(argv)` — non-interactive children (per-finding
    #     `hive accept-finding` / `hive reject-finding` toggles in
    #     triage mode). `Open3.capture3` runs the child without
    #     touching the alt-screen, so the screen never flashes on
    #     every keystroke.
    #
    # Both manage SubprocessRegistry around the spawn so the SIGHUP
    # cleanup hook (in `App.run_charm`) can kill the in-flight child
    # group on shutdown, and both restore the parent's INT/TERM trap
    # handlers in `ensure` regardless of exit shape (clean, signal,
    # exception). The pgid+trap idiom mirrors `Hive::Agent#spawn_and_wait`
    # (lib/hive/agent.rb:99-117).
    module Subprocess
      module_function

      # Returns Integer exit status. For signal-killed children, returns
      # `128 + signo` (POSIX shell convention) so callers see a non-zero,
      # non-overlapping value instead of nil.
      # POSIX shells use 127 for "command not found"; reuse it so the TUI
      # caller can flash a stable status without ambiguating between a
      # missing binary and an explicit child exit code.
      COMMAND_NOT_FOUND_EXIT = 127

      # Charm path: returns a `Bubbletea::SequenceCommand` that, when
      # run by the framework's runner, exits alt-screen, spawns argv
      # with pgroup forwarding, waits, re-enters alt-screen, and
      # dispatches a `Messages::SubprocessExited(verb:, exit_code:)`
      # back into the loop via `dispatch.call(message)`.
      #
      # Why the alt-screen toggle is necessary: bubbletea-ruby's
      # `Runner#exec_process` only toggles raw mode + cursor + input
      # reader for the child — it does NOT exit alt-screen. With
      # `alt_screen: true` (which the TUI uses), the child's stdout
      # writes paint into the alt-screen buffer instead of the main
      # terminal, and on return the renderer's diff state is corrupted
      # (subsequent frames append below the buffered output instead of
      # redrawing in place). Wrapping in a sequence with
      # `exit_alt_screen` → exec → `enter_alt_screen` makes the child
      # write to the main screen and forces a clean alt-screen
      # re-render on return. Documented in U2 verification:
      # `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`.
      #
      # The `dispatch:` parameter is the seam for runner injection.
      # `App.run_charm` wires `dispatch: runner.method(:send)`. Tests
      # pass a plain capture lambda. We can't use the framework
      # builder's built-in `message:` argument because the exit code
      # isn't known at command-construction time — closure-capture is
      # the only path that surfaces the actual exit code.
      #
      # Verb is cached at argv[1] at construction time so SubprocessExited
      # carries the verb name even if argv mutates downstream — same
      # contract as `Messages::DispatchCommand.verb`.
      def takeover_command(argv, dispatch:)
        verb = argv[1]
        callable = lambda do
          exit_code = run_takeover_child(argv)
          dispatch.call(Messages::SubprocessExited.new(verb: verb, exit_code: exit_code))
        end
        Bubbletea.sequence(
          Bubbletea.exit_alt_screen,
          Bubbletea.public_send(:exec, callable),
          Bubbletea.enter_alt_screen
        )
      end

      # Subprocess stderr log path. Workflow verbs spawned via
      # `takeover_command` redirect stderr to this file (append). The
      # alt-screen reasserts immediately after the child exits, so any
      # error output would otherwise scroll off-screen too fast to read;
      # writing to a log lets the user `tail` it on a non-zero exit.
      # Stdout stays inherited so interactive prompts (gh pr create,
      # claude tool-permission asks) still work end-to-end.
      SUBPROCESS_LOG_PATH = File.join(Dir.tmpdir, "hive-tui-subprocess.log").freeze

      # Spawn-and-wait core. Returns the same Integer exit shape:
      # 0..255 for clean exits, 128+signo for signal kills,
      # COMMAND_NOT_FOUND_EXIT (127) for missing binary.
      #
      # Stderr is redirected (append) to `SUBPROCESS_LOG_PATH` so the
      # user can `tail` it on a non-zero exit; alt-screen reasserts too
      # fast for the operator to read errors otherwise. Stdout stays
      # inherited so interactive prompts (gh pr create, claude tool
      # permissions) round-trip cleanly.
      def run_takeover_child(argv)
        Hive::Tui::Debug.log("takeover_command", "argv=#{argv.inspect}")
        prev_int, prev_term = install_pgid_forwarding_traps
        begin
          stamp_subprocess_log("BEGIN", argv)
          pid = Process.spawn(*argv, pgroup: true, err: [ SUBPROCESS_LOG_PATH, "a" ])
          register_real_pgid(pid)
          Hive::Tui::Debug.log("takeover_command", "pid=#{pid} pgid=#{SubprocessRegistry.current.inspect}")
          _, status = Process.wait2(pid)
          exit_code = translate_status(status)
          stamp_subprocess_log("END exit=#{exit_code}", argv)
          exit_code
        rescue Errno::ENOENT, Errno::EACCES => e
          Hive::Tui::Debug.log("takeover_command", "errno=#{e.class.name}: #{e.message}")
          stamp_subprocess_log("ERRNO #{e.class.name}: #{e.message}", argv)
          COMMAND_NOT_FOUND_EXIT
        ensure
          SubprocessRegistry.clear
          restore_traps(prev_int, prev_term)
        end
      end

      # @api private
      # Append a marker line so the log can be read as a stream of
      # per-verb sections. Failures with empty stderr (e.g., signal
      # kill) still leave the BEGIN/END pair so the operator knows
      # which verb produced which exit code.
      def stamp_subprocess_log(label, argv)
        File.open(SUBPROCESS_LOG_PATH, "a") do |f|
          f.puts "----- #{Time.now.utc.iso8601} #{label}: #{argv.join(' ')} -----"
        end
      rescue StandardError
        nil
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
