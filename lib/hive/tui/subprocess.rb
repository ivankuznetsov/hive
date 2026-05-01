require "open3"
require "securerandom"
require "tmpdir"
require "fileutils"
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
      #     detached with stdout/stderr redirected to a per-spawn capture
      #     file at `<tmpdir>/hive-tui-spawn-<id>.log` (named with the
      #     same 8-char hex ID embedded in the BEGIN/END markers in
      #     `SUBPROCESS_LOG_PATH`). Returns immediately. A reaper Thread
      #     waits for the child, deletes the per-spawn capture on
      #     exit_code == 0 (success has nothing to diagnose) and keeps
      #     it on non-zero exits, then dispatches
      #     `Messages::SubprocessExited(verb:, exit_code:)`. Multiple
      #     concurrent agents (across projects) work — the TUI keeps
      #     polling and rendering while children run, and a noisy child
      #     can no longer grow the shared log past its rotation cap
      #     because child output never lands in the shared file.
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
      COMMAND_TIMEOUT_EXIT = 124
      RUN_QUIET_TIMEOUT_SECONDS = 30

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
        spawn_id = generate_correlation_id
        stamp_subprocess_log("BEGIN", argv, id: spawn_id)
        sweep_old_spawn_captures!

        pid = spawn_background_child(argv, spawn_id)
        if pid.nil?
          dispatch.call(Messages::SubprocessExited.new(verb: verb, exit_code: COMMAND_NOT_FOUND_EXIT))
          return nil
        end

        spawn_reaper_thread(pid, verb, argv, dispatch, spawn_id)
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
        spawn_id = generate_correlation_id
        stamp_subprocess_log("BEGIN(interactive)", argv, id: spawn_id)
        pid = Process.spawn(*argv, pgroup: true)
        _, status = Process.wait2(pid)
        exit_code = translate_status(status)
        stamp_subprocess_log("END(interactive) exit=#{exit_code}", argv, id: spawn_id)
        exit_code
      rescue Errno::ENOENT, Errno::EACCES => e
        Hive::Tui::Debug.log("takeover_command", "errno=#{e.class.name}: #{e.message}")
        stamp_subprocess_log("ERRNO(interactive) #{e.class.name}: #{e.message}", argv)
        COMMAND_NOT_FOUND_EXIT
      end

      # @api private
      def spawn_background_child(argv, spawn_id)
        path = spawn_capture_path(spawn_id)
        FileUtils.mkdir_p(File.dirname(path))
        Process.spawn(
          *argv,
          pgroup: true,
          out: [ path, "a" ],
          err: [ path, "a" ]
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
      def spawn_reaper_thread(pid, verb, argv, dispatch, spawn_id = nil)
        Thread.new do
          _, status = Process.wait2(pid)
          exit_code = translate_status(status)
          stamp_subprocess_log("END exit=#{exit_code}", argv, id: spawn_id)
          # Successful spawns have nothing to diagnose — drop the
          # capture file so disk usage stays bounded by failures, not
          # by overall spawn count. Failures keep their capture so
          # diagnose_recent_failure can read it.
          if spawn_id && exit_code.zero?
            delete_spawn_capture(spawn_id)
          elsif spawn_id
            bound_spawn_capture(spawn_id)
          end
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

      # Per-spawn capture file path. `dispatch_background` redirects
      # the child's stdout/stderr here (one file per spawn, named with
      # the same 8-char hex ID embedded in the BEGIN/END markers in
      # `SUBPROCESS_LOG_PATH`). Successful spawns delete their capture
      # in the reaper; failed spawns keep theirs so
      # `diagnose_recent_failure` can read the actual stderr.
      def spawn_capture_path(spawn_id)
        File.join(log_dir, "hive-tui-spawn-#{spawn_id}.log")
      end

      # Best-effort delete; the reaper-or-sweep flow tolerates an
      # already-gone file.
      def delete_spawn_capture(spawn_id)
        File.delete(spawn_capture_path(spawn_id))
      rescue Errno::ENOENT
        nil
      rescue StandardError => e
        Hive::Tui::Debug.log("dispatch_background", "delete_spawn_capture #{spawn_id}: #{e.class.name}")
      end

      # Belt-and-suspenders cleanup: remove orphaned capture files
      # older than SPAWN_CAPTURE_MAX_AGE_SECONDS. Crashed reapers,
      # killed-then-rebooted TUI sessions, and `kill -9 hive` all
      # leave files behind that the success-path delete never runs
      # against. Sweep at every BEGIN — hot enough to keep the dir
      # bounded, cheap enough to not matter (one Dir.glob + N stat
      # calls).
      SPAWN_CAPTURE_MAX_AGE_SECONDS = 24 * 60 * 60 # 24h
      SPAWN_CAPTURE_MAX_BYTES = 1024 * 1024

      def sweep_old_spawn_captures!
        cutoff = Time.now - SPAWN_CAPTURE_MAX_AGE_SECONDS
        Dir.glob(File.join(log_dir, "hive-tui-spawn-*.log")).each do |path|
          File.delete(path) if File.mtime(path) < cutoff
        rescue Errno::ENOENT
          nil
        end
      rescue StandardError => e
        Hive::Tui::Debug.log("dispatch_background", "sweep_old_spawn_captures: #{e.class.name}")
      end

      def bound_spawn_capture(spawn_id)
        path = spawn_capture_path(spawn_id)
        return unless File.exist?(path)
        return if File.size(path) <= SPAWN_CAPTURE_MAX_BYTES

        notice = "[truncated to last #{SPAWN_CAPTURE_MAX_BYTES} bytes]\n"
        retained_bytes = [ SPAWN_CAPTURE_MAX_BYTES - notice.bytesize, 0 ].max
        File.write(path, "#{notice}#{tail_bytes(path, retained_bytes)}")
      rescue StandardError => e
        Hive::Tui::Debug.log("dispatch_background", "bound_spawn_capture #{spawn_id}: #{e.class.name}")
      end

      # The shared marker log: BEGIN[id] / END[id] / ERRNO records
      # only — child stdout/stderr lives in per-spawn capture files
      # (see `spawn_capture_path`). Pre-spawn-capture, this file
      # collected child stdio too and grew unboundedly between the
      # rotation checkpoints; with per-spawn capture, it carries one
      # short marker line per BEGIN/END pair, so the disk-usage cap
      # below is now a real bound.
      SUBPROCESS_LOG_PATH = File.join(Dir.tmpdir, "hive-tui-subprocess.log").freeze

      # Pre-write rotation cap, checked at every BEGIN/END stamp.
      # When `SUBPROCESS_LOG_PATH` exceeds SUBPROCESS_LOG_MAX_BYTES,
      # rename it to `SUBPROCESS_LOG_PATH.1` (overwriting any prior
      # rotated copy) so the next stamp starts fresh. Now actually
      # bounded since child output no longer lands here.
      SUBPROCESS_LOG_MAX_BYTES = 10 * 1024 * 1024

      def log_dir
        ENV["HIVE_TUI_LOG_DIR"].to_s.empty? ? Dir.tmpdir : ENV["HIVE_TUI_LOG_DIR"]
      end

      def log_path
        ENV["HIVE_TUI_LOG_DIR"].to_s.empty? ? SUBPROCESS_LOG_PATH : File.join(log_dir, "hive-tui-subprocess.log")
      end

      # Spawn-and-wait core. Returns the same Integer exit shape:
      # 0..255 for clean exits, 128+signo for signal kills,
      # COMMAND_NOT_FOUND_EXIT (127) for missing binary.
      #
      # @api private
      # Append a marker line so the log can be read as a stream of
      # per-verb sections. Failures with empty stderr (e.g., signal
      # kill) still leave the BEGIN/END pair so the operator knows
      # which verb produced which exit code.
      #
      # `id:` is a per-spawn 8-char hex correlation ID (F7). Embedded
      # in the BEGIN/END label as `BEGIN[ID]` / `END[ID] exit=N` so
      # `recent_log_section_for` can pair the right BEGIN with the
      # right END under concurrent verbs. Without it, two verbs
      # interleaving BEGIN/END marker lines produced cross-talk
      # diagnostics.
      def stamp_subprocess_log(label, argv, id: nil)
        rotate_subprocess_log_if_needed
        annotated = id ? annotate_label_with_id(label, id) : label
        path = log_path
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "a") do |f|
          f.puts "----- #{Time.now.utc.iso8601} #{annotated}: #{argv.join(' ')} -----"
        end
      rescue StandardError
        nil
      end

      # @api private
      # Rotate when the log exceeds SUBPROCESS_LOG_MAX_BYTES. Renames
      # the current file to `<path>.1` (overwriting any prior rotation),
      # leaving the next stamp_subprocess_log to recreate the primary
      # file via append-open. Best-effort: any errno here (Errno::*,
      # bumped permissions, parallel rotator, etc.) is swallowed and
      # the next caller will simply append to the existing oversized
      # file; correctness still holds, just no rotation that round.
      def rotate_subprocess_log_if_needed
        path = log_path
        size = File.size?(path).to_i
        return if size <= SUBPROCESS_LOG_MAX_BYTES

        File.rename(path, "#{path}.1")
      rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM
        nil
      end

      # @api private
      # Insert `[ID]` after the keyword (BEGIN, END, or BEGIN(...)/END(...))
      # but before any trailing ` exit=N` suffix on END labels, so the
      # parser regex can split on `END[ID] exit=` cleanly.
      def annotate_label_with_id(label, id)
        if label =~ /\AEND(\([^)]+\))?(\s+exit=.*)?\z/
          paren = Regexp.last_match(1).to_s
          tail = Regexp.last_match(2).to_s
          "END#{paren}[#{id}]#{tail}"
        elsif label =~ /\ABEGIN(\([^)]+\))?\z/
          paren = Regexp.last_match(1).to_s
          "BEGIN#{paren}[#{id}]"
        else
          # ERRNO and other label shapes don't get IDs — they're
          # self-contained, no matching END to pair with.
          label
        end
      end

      # @api private
      # 8 hex chars = 32 bits = ~4B distinct IDs; collision probability
      # over the rolling 64KB log tail (~1000 BEGIN entries) is
      # negligible. Smaller than UUID, large enough to disambiguate.
      def generate_correlation_id
        bytes = SecureRandom.random_bytes(4)
        bytes.unpack1("H*")
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
        return nil unless File.exist?(log_path)

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
      # Find the most recent BEGIN[id] for `verb` in the marker log;
      # return the matching per-spawn capture file's contents (the
      # actual child stderr, capped at 64KB tail). Returns nil if no
      # BEGIN-for-verb is present, or if its capture file is gone (the
      # success-path delete fired, or the sweep reaped an orphan).
      #
      # Falls back to reading the section from the marker log itself
      # for entries that lack a correlation ID (legacy logs from
      # before per-spawn capture landed). The fallback returns the
      # text BEGIN..matching-END just like the pre-rewrite behavior.
      def recent_log_section_for(verb)
        cap = 64 * 1024
        path = log_path
        size = File.size(path)
        offset = [ size - cap, 0 ].max
        text = File.open(path, "r") do |f|
          f.seek(offset)
          f.read
        end
        begin_re = /^----- [^\n]* BEGIN(?:\([^)]+\))?(?:\[(?<id>[0-9a-f]{8})\])?: hive #{Regexp.escape(verb.to_s)}\b[^\n]* -----$/
        begin_match = text.enum_for(:scan, begin_re).map { Regexp.last_match }.last
        return nil if begin_match.nil?

        spawn_id = begin_match[:id]
        if spawn_id && File.exist?(spawn_capture_path(spawn_id))
          # Prepend the BEGIN line so `parse_argv_from_section` can
          # still read it as the section's first line. Without this,
          # `extract_project` runs against stderr and loses the
          # `--project` flag — multi-project users would see an
          # unscoped diagnostic flash.
          capture = read_spawn_capture(spawn_id, cap)
          return capture.nil? ? nil : "#{begin_match[0]}\n#{capture}"
        end

        # Legacy fallback: section text from the marker log itself.
        # Hits when the entry pre-dates per-spawn capture, when the
        # capture was deleted (successful spawn — but we wouldn't be
        # diagnosing in that case anyway), or for the interactive
        # takeover path which has no per-spawn file.
        section_start = text.rindex(begin_match[0])
        end_idx = locate_matching_end(text, spawn_id, section_start) || text.length
        text[section_start..end_idx]
      end

      # @api private
      def read_spawn_capture(spawn_id, cap)
        path = spawn_capture_path(spawn_id)
        size = File.size(path)
        offset = [ size - cap, 0 ].max
        File.open(path, "r") do |f|
          f.seek(offset)
          f.read
        end
      rescue Errno::ENOENT
        nil
      end

      def tail_bytes(path, bytes)
        File.open(path, "rb") do |file|
          size = file.size
          file.seek([ size - bytes, 0 ].max)
          file.read
        end
      end

      # @api private
      # Find the offset of the matching END[id] for a BEGIN at
      # `section_start`. When `id` is nil (legacy entry without
      # correlation), falls back to the first END-of-any-verb after
      # section_start (the pre-F7 best-effort).
      def locate_matching_end(text, id, section_start)
        if id
          target = /^----- [^\n]* END(?:\([^)]+\))?\[#{Regexp.escape(id)}\] exit=[^\n]* -----$/
        else
          target = /^----- [^\n]* END(?:\([^)]+\))?(?:\[[0-9a-f]{8}\])? exit=[^\n]* -----$/
        end
        text.index(target, section_start)
      end

      # @api private
      def parse_argv_from_section(section)
        first = section.lines.first.to_s
        # Match `BEGIN:`, `BEGIN(interactive):`, and the F7 variants
        # carrying a correlation ID (`BEGIN[ID]:` / `BEGIN(interactive)[ID]:`).
        m = first.match(/BEGIN(?:\([^)]+\))?(?:\[[0-9a-f]{8}\])?: (.+) -----$/)
        m ? m[1].split(/\s+/) : nil
      end

      # @api private
      def extract_project(argv)
        idx = argv.index("--project")
        return nil if idx.nil?

        argv[idx + 1]
      end

      # Returns [exit_status, stdout, stderr]. The child is timeout-bounded
      # and runs in its own process group so quitting or interrupting the TUI
      # cannot leave a captured-stdio helper behind.
      def run_quiet!(argv)
        Hive::Tui::Debug.log("run_quiet", "argv=#{argv.inspect}")
        out, err, status = bounded_capture3(*argv, timeout: RUN_QUIET_TIMEOUT_SECONDS)
        exit_code = translate_status(status)
        Hive::Tui::Debug.log("run_quiet", "exit=#{exit_code} out_bytes=#{out.bytesize} err_bytes=#{err.bytesize}")
        [ exit_code, out, err ]
      rescue Errno::ENOENT, Errno::EACCES => e
        Hive::Tui::Debug.log("run_quiet", "errno=#{e.class.name}: #{e.message}")
        [ COMMAND_NOT_FOUND_EXIT, "", "command not found: #{argv.first}" ]
      rescue TimeoutError => e
        Hive::Tui::Debug.log("run_quiet", "timeout=#{e.elapsed.round(2)}s argv=#{argv.inspect}")
        [ COMMAND_TIMEOUT_EXIT, e.stdout, "command timed out after #{e.elapsed.round(2)}s: #{argv.join(' ')}\n#{e.stderr}" ]
      end

      # --- private helpers ---------------------------------------------------

      TimeoutError = Class.new(StandardError) do
        attr_reader :stdout, :stderr, :elapsed

        def initialize(stdout:, stderr:, elapsed:)
          @stdout = stdout
          @stderr = stderr
          @elapsed = elapsed
          super("subprocess timed out after #{format('%.2f', elapsed)}s")
        end
      end

      def bounded_capture3(*cmd, timeout:)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          out_reader = Thread.new { read_stream(stdout) }
          err_reader = Thread.new { read_stream(stderr) }
          loop do
            if wait_thr.join(0.05)
              return [ out_reader.value, err_reader.value, wait_thr.value ]
            end

            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            next if elapsed < timeout

            terminate_process_group(wait_thr.pid)
            raise TimeoutError.new(stdout: safe_thread_value(out_reader), stderr: safe_thread_value(err_reader), elapsed: elapsed)
          end
        end
      end

      def read_stream(stream)
        stream.read
      rescue IOError
        ""
      end

      def terminate_process_group(pid)
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH
        nil
      ensure
        sleep 0.1
        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH
          nil
        end
      end

      def safe_thread_value(thread)
        thread.kill if thread.alive?
        thread.value.to_s
      rescue StandardError
        ""
      end

      # NOTE: install_pgid_forwarding_traps / restore_traps /
      # forward_signal_to_inflight / register_real_pgid were deleted
      # along with run_quiet!'s trap-install path (F9). The
      # SubprocessRegistry module itself is still loadable for the
      # signal cleanup hook in App.run_charm, but no production caller
      # writes to its slot anymore: workflow verbs route through
      # dispatch_background (detached pgroup, not registered) and
      # run_quiet! uses Open3.capture3 (also not registered).

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
