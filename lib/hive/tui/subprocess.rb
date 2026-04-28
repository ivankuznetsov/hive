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
    #   * `dispatch_background(argv, dispatch:)` — workflow verbs (hive
    #     brainstorm/plan/develop/review/pr/archive). Spawns the child
    #     detached with stdio redirected to `SUBPROCESS_LOG_PATH`, returns
    #     immediately. A reaper Thread waits for the child and dispatches
    #     `Messages::SubprocessExited(verb:, exit_code:)`. Multiple
    #     concurrent agents (across projects) work — the TUI keeps
    #     polling and rendering while children run.
    #   * `run_quiet!(argv)` — synchronous, captured-stdio children
    #     for per-finding `hive accept-finding` / `hive reject-finding`
    #     toggles in triage mode. `Open3.capture3` runs the child
    #     without touching the alt-screen so the screen never flashes
    #     on every keystroke.
    #
    # `run_quiet!` does NOT install INT/TERM forwarding traps or touch
    # the SubprocessRegistry. `Open3.capture3` manages the child
    # internally, and the per-keystroke triage subprocesses are short-
    # lived enough that the user can simply press `r` again on Ctrl-C.
    # The historical install/restore_traps pairing was dead code: it
    # registered `:placeholder` and never called `register_real_pgid`,
    # so the trap blocks always short-circuited and INT forwarding
    # silently no-op'd anyway. Removing it also closes the concurrent-
    # `run_quiet!` trap-chain race the audit flagged (F5/F9).
    # `dispatch_background` likewise does NOT install signal
    # forwarding — the child is detached into its own pgroup, and the
    # TUI can quit without killing its agents (intentional: long-running
    # agents outlive the dashboard).
    module Subprocess
      module_function

      # Returns Integer exit status. For signal-killed children, returns
      # `128 + signo` (POSIX shell convention) so callers see a non-zero,
      # non-overlapping value instead of nil.
      # POSIX shells use 127 for "command not found"; reuse it so the TUI
      # caller can flash a stable status without ambiguating between a
      # missing binary and an explicit child exit code.
      COMMAND_NOT_FOUND_EXIT = 127

      # Background spawn for workflow verbs (hive brainstorm/plan/
      # develop/review/pr/archive). Returns nil (no Bubbletea Cmd) —
      # the TUI keeps running its render loop while the child runs in
      # parallel; multiple agents across multiple projects can run
      # concurrently. A reaper Thread waits for the child and
      # dispatches `Messages::SubprocessExited(verb:, exit_code:)` so
      # the TUI flashes the result.
      #
      # Why no foreground takeover: the workflow verbs invoke
      # `Hive::Agent` which spawns `claude` with captured stdio
      # (`IO.pipe` to `task.log_dir/<label>-<ts>.log`). The child
      # never needs the user's tty — taking over would only block the
      # TUI for no benefit, and force serial agent runs.
      #
      # Stdout + stderr both redirect to `SUBPROCESS_LOG_PATH` (append)
      # so a per-verb tail is available without corrupting the TUI's
      # alt-screen. The agent's own structured log lands separately
      # in `task.log_dir/*.log` (visible via Enter on agent_running rows).
      #
      # Pgroup leadership preserved: signal forwarding from the TUI
      # parent isn't installed (the child detaches into its own
      # group via `pgroup: true`); the SubprocessRegistry single-slot
      # tracking is bypassed because background spawns can be
      # concurrent and the registry doesn't model that. SIGHUP on the
      # TUI lets background children continue independently — by
      # design, since the user may want the agent to finish even if
      # they exit the TUI.
      def dispatch_background(argv, dispatch:)
        verb = argv[1]
        Hive::Tui::Debug.log("dispatch_background", "argv=#{argv.inspect}")
        stamp_subprocess_log("BEGIN", argv)

        pid = spawn_background_child(argv)
        if pid.nil?
          dispatch.call(Messages::SubprocessExited.new(verb: verb, exit_code: COMMAND_NOT_FOUND_EXIT))
          return nil
        end

        spawn_reaper_thread(pid, verb, argv, dispatch)
        nil
      end

      # Foreground takeover for verbs that need the user's tty (stdin
      # prompts, interactive `gh pr create`, claude tool-permission
      # asks). Returns a `Bubbletea::SequenceCommand` that:
      #
      #   1. exit_alt_screen → terminal returns to normal so the child
      #      writes to the main screen the user is looking at
      #   2. exec(callable) → callable runs synchronously inside the
      #      runner's suspend window (raw mode disabled, cursor shown,
      #      input reader stopped). The callable spawns argv with
      #      stdio inherited and waits for the exit code.
      #   3. enter_alt_screen → re-enters alt-screen, triggers full
      #      re-render via `renderer_set_alt_screen`.
      #
      # Used only for verbs flagged `interactive: true` in
      # `Hive::Workflows::VERBS` — the default headless verbs go
      # through `dispatch_background` which doesn't block the TUI.
      #
      # No `out:` / `err:` redirect: the child writes directly to the
      # user's terminal (which is in main-screen mode during the
      # callable, so the alt-screen buffer isn't corrupted). The
      # subprocess log doesn't capture this output — that's the trade
      # for actually showing the child to the user.
      def takeover_command(argv, dispatch:)
        verb = argv[1]
        callable = lambda do
          exit_code = run_takeover_child_sync(argv)
          dispatch.call(Messages::SubprocessExited.new(verb: verb, exit_code: exit_code))
        end
        Bubbletea.sequence(
          Bubbletea.exit_alt_screen,
          Bubbletea.public_send(:exec, callable),
          Bubbletea.enter_alt_screen
        )
      end

      # @api private
      # Foreground spawn-and-wait. Stdin/stdout/stderr inherited so the
      # user can answer prompts. Same pgroup + ENOENT translation as
      # the background path.
      def run_takeover_child_sync(argv)
        Hive::Tui::Debug.log("takeover_command", "argv=#{argv.inspect}")
        stamp_subprocess_log("BEGIN(interactive)", argv)
        pid = Process.spawn(*argv, pgroup: true)
        _, status = Process.wait2(pid)
        exit_code = translate_status(status)
        stamp_subprocess_log("END(interactive) exit=#{exit_code}", argv)
        exit_code
      rescue Errno::ENOENT, Errno::EACCES => e
        Hive::Tui::Debug.log("takeover_command", "errno=#{e.class.name}: #{e.message}")
        stamp_subprocess_log("ERRNO(interactive) #{e.class.name}: #{e.message}", argv)
        COMMAND_NOT_FOUND_EXIT
      end

      # @api private
      def spawn_background_child(argv)
        Process.spawn(
          *argv,
          pgroup: true,
          out: [ SUBPROCESS_LOG_PATH, "a" ],
          err: [ SUBPROCESS_LOG_PATH, "a" ]
        )
      rescue Errno::ENOENT, Errno::EACCES => e
        Hive::Tui::Debug.log("dispatch_background", "errno=#{e.class.name}: #{e.message}")
        stamp_subprocess_log("ERRNO #{e.class.name}: #{e.message}", argv)
        nil
      end

      # @api private
      # Wait for the child in a separate Ruby thread, dispatch
      # SubprocessExited on completion. Each background spawn gets
      # its own reaper — concurrent agents reap independently.
      #
      # Lifecycle relative to `Bubbletea::Runner.run`:
      #
      # * **Normal case** — runner is alive when `wait2` returns;
      #   dispatch fires; runner picks up the message at the top of
      #   its next loop tick; flash surfaces.
      # * **User quits the TUI while the agent is running** — the
      #   `App.run_charm` `ensure` block tears the runner down. The
      #   spawned child KEEPS RUNNING (no INT/TERM forwarding from
      #   the parent in dispatch_background — children are detached
      #   into their own pgroup so a long brainstorm finishes even
      #   if the dashboard exits). When `wait2` eventually returns
      #   in this Thread, `dispatch.call` lands on a dead runner;
      #   the inner rescue catches the resulting error, logs it,
      #   and exits silently. **The outer rescue's StandardError
      #   does double duty**: it handles both `wait2` failures
      #   (ECHILD / pid tracking bugs → synthesize `exit_code: -1`)
      #   AND post-shutdown dispatch attempts. Both end up logged via
      #   Debug; nothing else cares about the orphaned reaper.
      # * **Reaper Thread error during normal-case dispatch** — same
      #   path as the post-shutdown one, but `dispatch.call(-1)`
      #   succeeds and the user sees "exited -1" on a live TUI.
      #
      # Trade: agents can outlive the dashboard (intentional, see
      # `dispatch_background`'s docstring on detached pgroup). The
      # cost is that we deliberately can't forward TERM through to
      # in-flight children at TUI shutdown — `q` quits the TUI but
      # the agents continue.
      def spawn_reaper_thread(pid, verb, argv, dispatch)
        Thread.new do
          _, status = Process.wait2(pid)
          exit_code = translate_status(status)
          stamp_subprocess_log("END exit=#{exit_code}", argv)
          dispatch.call(Messages::SubprocessExited.new(verb: verb, exit_code: exit_code))
        rescue StandardError => e
          # `wait2` raised (ECHILD / pid tracking bug) — synthesize
          # an exit so the user's "running …" flash resolves to
          # "exited -1" rather than appearing wedged.
          Hive::Tui::Debug.log("dispatch_background", "reaper: #{e.class.name}: #{e.message}")
          begin
            dispatch.call(Messages::SubprocessExited.new(verb: verb, exit_code: -1))
          rescue StandardError => inner
            # Runner torn down before we got here (post-quit reaper)
            # — logged and silenced. See lifecycle note above.
            Hive::Tui::Debug.log("dispatch_background", "reaper-dispatch: #{inner.class.name}")
          end
        end
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

      # Map well-known stderr substrings emitted by the underlying CLI
      # (git, gh, ssh, etc.) to short, action-oriented flash text the
      # TUI can show in place of "`<verb>` exited N — tail …". Helps
      # the user immediately see *why* the verb failed for the common
      # setup-class errors that are not a hive bug. Each entry is a
      # [pattern, formatter] pair; formatter receives argv so it can
      # name the project / slug.
      DIAGNOSTIC_PATTERNS = [
        [
          /'origin' does not appear to be a git repository|Could not read from remote repository/,
          ->(argv) {
            project = extract_project(argv)
            prefix = project ? "#{project}: " : ""
            "#{prefix}project not set up — git remote 'origin' missing. Create the repo + add origin in a sibling shell, then retry."
          }
        ],
        [
          /gh: command not found/,
          ->(_argv) { "`gh` CLI not installed — install it (e.g. `brew install gh`), then retry." }
        ],
        [
          /Permission denied \(publickey\)/,
          ->(_argv) { "git auth failed (no SSH key) — check `gh auth status` or your SSH agent, then retry." }
        ]
      ].freeze

      # Returns a friendly diagnostic string for the most recent
      # subprocess section in SUBPROCESS_LOG_PATH, or nil when nothing
      # matches a known pattern. Called by `BubbleModel#handle_side_effect`
      # on `Messages::SubprocessExited` with non-zero exit code; if a
      # diagnostic is available, the TUI flashes that instead of the
      # generic "exited N — tail …" hint.
      #
      # The lookup is best-effort: it reads the tail of the log,
      # finds the most recent BEGIN that mentions the verb, and treats
      # everything between that BEGIN and the next END as the verb's
      # captured stderr. Concurrent verbs may interleave at line
      # boundaries; if a pattern still matches we still show the
      # diagnostic — false-positive risk is low because the patterns
      # are specific.
      def diagnose_recent_failure(verb)
        return nil unless File.exist?(SUBPROCESS_LOG_PATH)

        section = recent_log_section_for(verb)
        return nil if section.nil? || section.strip.empty?

        argv = parse_argv_from_section(section) || []
        match = DIAGNOSTIC_PATTERNS.find { |pattern, _| section.match?(pattern) }
        return nil unless match

        match[1].call(argv)
      rescue StandardError => e
        Hive::Tui::Debug.log("diagnose", "failed: #{e.class.name}: #{e.message}")
        nil
      end

      # @api private
      # Read the file tail (cap at 64KB so a long-lived log doesn't
      # explode memory), find the most recent BEGIN line mentioning
      # the verb, return the text from that BEGIN through the next
      # END (or EOF). Returns nil if no BEGIN-for-verb is present.
      def recent_log_section_for(verb)
        cap = 64 * 1024
        size = File.size(SUBPROCESS_LOG_PATH)
        offset = [ size - cap, 0 ].max
        text = File.open(SUBPROCESS_LOG_PATH, "r") do |f|
          f.seek(offset)
          f.read
        end
        # The `(?:\([^)]+\))?` allows both "BEGIN:" (background-spawn)
        # and "BEGIN(interactive):" (foreground takeover) — without it
        # diagnostic lookup silently breaks for any future verb flagged
        # `interactive: true` in `Hive::Workflows::VERBS`.
        begin_re = /^----- [^\n]* BEGIN(?:\([^)]+\))?: hive #{Regexp.escape(verb.to_s)}\b[^\n]* -----$/
        begin_match = text.enum_for(:scan, begin_re).map { Regexp.last_match }.last
        return nil if begin_match.nil?

        section_start = text.rindex(begin_match[0])
        end_idx = text.index(/^----- [^\n]* END(?:\([^)]+\))? exit=[^\n]* -----$/, section_start) || text.length
        text[section_start..end_idx]
      end

      # @api private
      def parse_argv_from_section(section)
        first = section.lines.first.to_s
        # Match both `BEGIN:` and `BEGIN(interactive):` (or any future
        # parenthesized variant) so the project lookup works for
        # interactive-takeover sections too.
        m = first.match(/BEGIN(?:\([^)]+\))?: (.+) -----$/)
        m ? m[1].split(/\s+/) : nil
      end

      # @api private
      def extract_project(argv)
        idx = argv.index("--project")
        return nil if idx.nil?

        argv[idx + 1]
      end

      # Returns [exit_status, stdout, stderr]. `Open3.capture3` manages
      # the child internally; the parent's INT/TERM trap chain stays
      # untouched, and the SubprocessRegistry is irrelevant for this
      # short-lived path (no `register_real_pgid` was ever called from
      # here, so the install/restore_traps pair was decorative — the
      # trap blocks read `:placeholder` and short-circuited).
      def run_quiet!(argv)
        Hive::Tui::Debug.log("run_quiet", "argv=#{argv.inspect}")
        out, err, status = Open3.capture3(*argv, pgroup: true)
        exit_code = status.exitstatus || -1
        Hive::Tui::Debug.log("run_quiet", "exit=#{exit_code} out_bytes=#{out.bytesize} err_bytes=#{err.bytesize}")
        [ exit_code, out, err ]
      rescue Errno::ENOENT, Errno::EACCES => e
        Hive::Tui::Debug.log("run_quiet", "errno=#{e.class.name}: #{e.message}")
        [ COMMAND_NOT_FOUND_EXIT, "", "command not found: #{argv.first}" ]
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
