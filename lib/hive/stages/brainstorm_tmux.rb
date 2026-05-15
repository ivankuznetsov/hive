require "fileutils"
require "open3"
require "time"

require "hive/agent_profiles"
require "hive/lock"
require "hive/markers"
require "hive/stages/brainstorm"
require "hive/stop_hook_installer"
require "hive/tmux_runner"

module Hive
  module Stages
    module BrainstormTmux
      READY_WAIT_TIMEOUT_SEC = 5
      DONE_POLL_INTERVAL_SEC = 0.5
      SENTINEL_POLL_INTERVAL_SEC = 5
      SENTINEL_CAPTURE_BYTES = 8192
      MIN_TMUX_VERSION = "3.0"
      TERMINAL_MARKERS = %i[waiting complete error].freeze

      module_function

      def run!(task, cfg)
        # `brainstorm.runtime=tmux_interactive` hardcodes the claude
        # binary (the wrapper script execs `claude` regardless), so
        # configuring `brainstorm.agent=codex|pi` is silently incoherent.
        # `hive doctor` warns about this, but doctor is advisory — flip
        # the config after doctor passes and the tmux spawn fails with
        # a confusing "claude not found". Surface the mismatch up-front.
        configured_agent = (cfg.dig("brainstorm", "agent") || "claude").to_s
        if configured_agent != "claude"
          raise Hive::AgentError,
                "brainstorm.runtime=tmux_interactive requires brainstorm.agent=claude, " \
                "got=#{configured_agent}"
        end

        profile = Hive::AgentProfiles.lookup(:claude, cfg: cfg)
        runner = build_runner(task)
        preflight!(profile, runner)
        # `reset_signal_files` deletes the previous run's `result.json`
        # forensic file, so it must run AFTER `preflight!` — a preflight
        # failure (missing tmux, name collision) destroys the prior
        # turn's forensic payload otherwise.
        reset_signal_files(task)

        prompt = Hive::Stages::Brainstorm.render_prompt(task, cfg, profile: profile)
        Hive::Markers.set(task.state_file, :agent_working,
                          pid: Process.pid,
                          started: Time.now.utc.iso8601)

        settings_path = nil
        begin
          settings_path = Hive::StopHookInstaller.install(stage_dir: task.folder)
          runner.start_detached(command: wrapper_command(task, profile))
          wait_until_session_exists!(runner)
          record_claude_pid(task, runner)
          runner.send_prompt(prompt)
          marker = wait_for_terminal_marker(task, runner, timeout_sec(cfg))
          { commit: Hive::Stages::Brainstorm.action_for(marker.name), status: marker.name }
        ensure
          # Each teardown step is wrapped in `safe { ... }` so a
          # transient failure in one (e.g. `CommandFailed` from
          # `kill_session`) does not skip the remaining steps and leak
          # the per-task `.claude/settings.json` or `.done`.
          safe { runner.kill_session if runner }
          safe { sweep_orphan_processes(task) }
          safe { cleanup_scratch(settings_path) }
          safe { cleanup_done(task) }
        end
      end

      # Run a teardown step, swallowing any exception so the next step
      # still runs. Used to guarantee that every step of the `ensure`
      # chain in `run!` executes regardless of which one raises.
      def safe
        yield
      rescue StandardError
        nil
      end

      def session_name_for(task)
        "hive-2-brainstorm-#{task.slug}"[0, 250]
      end

      def build_runner(task)
        Hive::TmuxRunner.new(
          name: session_name_for(task),
          cwd: task.folder,
          env: {
            "ANTHROPIC_API_KEY" => "",
            "CLAUDE_API_KEY" => "",
            "HIVE_TASK_STAGE_DIR" => task.folder
          },
          tmux_bin: tmux_bin,
          socket_name: ENV["HIVE_TMUX_SOCKET"]
        )
      end

      def preflight!(profile, runner)
        preflight_tmux!
        profile.check_version!
        if runner.session_exists?
          raise Hive::AgentError,
                "tmux session #{runner.name} already exists; attach with `tmux attach -t #{runner.name}` " \
                "or run `tmux kill-session -t #{runner.name}` to clear it before retrying"
        end
      end

      def preflight_tmux!(tmux_bin: self.tmux_bin)
        out, err, status = Open3.capture3(tmux_bin, "-V")
        unless status.success?
          raise Hive::AgentError, "tmux not runnable: #{tmux_bin} #{err.strip}"
        end

        version = parse_tmux_version(out)
        unless version
          raise Hive::AgentError, "could not parse tmux -V output: #{out.inspect}"
        end

        if (version_tuple(version) <=> version_tuple(MIN_TMUX_VERSION)).negative?
          raise Hive::AgentError, "tmux #{version} below minimum #{MIN_TMUX_VERSION}"
        end

        version
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Hive::AgentError, "tmux binary not runnable: #{tmux_bin} (#{e.class.name.split('::').last}: #{e.message})"
      end

      # Distinguish "no tmux installed" from "tmux installed but below
      # the minimum supported version" so the operator can see at a
      # glance whether to install or upgrade. `:version_too_old` is a
      # separate status row but still contributes to doctor's exit code
      # (treated as missing by the renderer's missing-skill check).
      def tmux_status(tmux_bin: self.tmux_bin)
        version = preflight_tmux!(tmux_bin: tmux_bin)
        [ :present, "tmux #{version} found" ]
      rescue Hive::AgentError => e
        status = e.message.include?("below minimum") ? :version_too_old : :missing
        [ status, e.message ]
      end

      def parse_tmux_version(output)
        output[/tmux\s+(\d+(?:\.\d+)?)/, 1]
      end

      def version_tuple(version)
        version.split(".").map(&:to_i)
      end

      def tmux_bin
        ENV.fetch("HIVE_TMUX_BIN", "tmux")
      end

      def wrapper_command(task, profile)
        [
          "bash",
          File.expand_path("../scripts/interactive_claude_wrapper.sh", __dir__),
          "--cwd", task.folder,
          "--add-dir", task.folder,
          "--bin", profile.bin
        ]
      end

      def wait_until_session_exists!(runner)
        deadline = Time.now + session_ready_wait_timeout
        until runner.session_exists?
          raise Hive::AgentError, "tmux session #{runner.name} did not start" if Time.now >= deadline

          sleep 0.1
        end
      end

      # Mirror the headless path's PID-into-task-lock contract so
      # `hive status`, signal routing, and observability tooling that
      # reads `claude_pid` find a value during an active brainstorm.
      #
      # The wrapper script execs into claude (`exec "$@"`), and `exec`
      # preserves the process's PID — so a pane PID captured while bash
      # is still running pre-exec is identical to the PID claude will
      # have after the exec lands. That's why we don't need a post-exec
      # re-read: there is no race, the same numeric PID denotes the
      # bash-pre-exec and the claude-post-exec process. A future reader
      # might be tempted to "fix" this by polling for a non-bash comm,
      # but that's unnecessary — the contract is PID identity, not
      # process-name freshness.
      #
      # We retry briefly because `display-message` can race the very
      # first pane process showing up at all.
      def record_claude_pid(task, runner)
        pid = nil
        deadline = Time.now + pid_ready_wait_timeout
        while pid.nil? && Time.now < deadline
          pid = runner.pane_pid
          break if pid

          sleep 0.05
        end
        return unless pid

        Hive::Lock.update_task_lock(task.folder, "claude_pid" => pid)
      rescue Hive::TmuxError
        nil
      end

      def wait_for_terminal_marker(task, runner, timeout)
        deadline = Time.now + timeout
        last_sentinel_check = Time.at(0)
        loop do
          if File.exist?(done_path(task))
            marker = Hive::Markers.current(task.state_file)
            return marker if terminal_marker?(marker)

            cleanup_done(task)
          end

          if Time.now - last_sentinel_check >= sentinel_poll_interval
            last_sentinel_check = Time.now
            marker = marker_from_sentinel_tail(task, runner)
            return marker if marker
          end

          if Time.now >= deadline
            Hive::Markers.set(task.state_file, :error, reason: "timeout", timeout_sec: timeout)
            return Hive::Markers.current(task.state_file)
          end

          sleep [ poll_interval, deadline - Time.now ].min
        end
      end

      def terminal_marker?(marker)
        TERMINAL_MARKERS.include?(marker.name)
      end

      def marker_from_sentinel_tail(task, runner)
        marker = Hive::Markers.current(task.state_file)
        return nil unless terminal_marker?(marker)

        pane = runner.capture_pane_tail(bytes: SENTINEL_CAPTURE_BYTES)
        names = pane.scan(Hive::Markers::MARKER_RE).map { |name, _| name.downcase.to_sym }
        names.include?(marker.name) ? marker : nil
      rescue Hive::TmuxError
        nil
      end

      def timeout_sec(cfg)
        Integer(cfg.dig("timeout_sec", "brainstorm"))
      end

      def poll_interval
        Float(ENV.fetch("HIVE_BRAINSTORM_TMUX_POLL_INTERVAL_SEC", DONE_POLL_INTERVAL_SEC.to_s))
      end

      def sentinel_poll_interval
        Float(ENV.fetch("HIVE_BRAINSTORM_TMUX_SENTINEL_INTERVAL_SEC", SENTINEL_POLL_INTERVAL_SEC.to_s))
      end

      # `session_ready_wait_timeout` and `pid_ready_wait_timeout` measure
      # unrelated things — tmux session creation vs. the claude PID
      # emerging in the pane after the wrapper execs. They share the
      # legacy `HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC` default so
      # the old single-knob tuning still works, but operators tuning one
      # condition can override it without silently affecting the other.
      def ready_wait_timeout
        Float(ENV.fetch("HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC", READY_WAIT_TIMEOUT_SEC.to_s))
      end

      def session_ready_wait_timeout
        Float(ENV.fetch("HIVE_BRAINSTORM_TMUX_SESSION_READY_WAIT_TIMEOUT_SEC",
                        ENV.fetch("HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC", READY_WAIT_TIMEOUT_SEC.to_s)))
      end

      def pid_ready_wait_timeout
        Float(ENV.fetch("HIVE_BRAINSTORM_TMUX_PID_READY_WAIT_TIMEOUT_SEC",
                        ENV.fetch("HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC", READY_WAIT_TIMEOUT_SEC.to_s)))
      end

      def reset_signal_files(task)
        cleanup_done(task)
        result = result_path(task)
        File.delete(result) if File.exist?(result)
      end

      ORPHAN_SWEEP_LOG_MAX_BYTES = 64 * 1024

      # Best-effort defensive sweep. tmux kill-session already terminates
      # the pane's descendents; this only catches orphans whose ancestry
      # is detached from the pane (rare). We log the pgrep match list and
      # the pkill exit status so silent kills surface in the orchestrator
      # log instead of getting swallowed when, e.g., task.folder is a
      # substring of another concurrent task's folder.
      #
      # The regex anchors the trailing edge with `(?:[[:space:]]|$)` so
      # a prefix sibling (task-a-extra vs. task-a) cannot match a longer
      # concurrent task's `--add-dir` value and get pkill'd. Without
      # the anchor the substring match would silently kill the sibling.
      def sweep_orphan_processes(task)
        pattern = "--add-dir[[:space:]]+#{Regexp.escape(task.folder)}(?:[[:space:]]|$)"
        matches, pgrep_err, pgrep_status = Open3.capture3("pgrep", "-fa", pattern)
        # `pgrep -fa` exit 1 with empty stdout means "no matches" — the
        # happy path. Any other non-zero (e.g. procps without `-a` on
        # minimal Alpine images) is a real failure: log a warning so it
        # doesn't get swallowed before pkill.
        if !pgrep_status.success? && pgrep_status.exitstatus != 1
          log_orphan_sweep_warning(task, "pgrep failed: exit=#{pgrep_status.exitstatus} err=#{pgrep_err.strip.inspect}")
          return
        end
        return if matches.strip.empty?

        out, err, status = Open3.capture3("pkill", "-f", pattern)
        log_orphan_sweep(task, matches, out, err, status)
      rescue Errno::ENOENT
        nil
      end

      def log_orphan_sweep(task, matches, out, err, status)
        log_path = orphan_sweep_log_path(task)
        rotate_orphan_sweep_log(log_path)
        File.open(log_path, "a") do |f|
          f.puts "[#{Time.now.utc.iso8601}] pgrep matches:"
          f.puts matches
          f.puts "[#{Time.now.utc.iso8601}] pkill exit=#{status&.exitstatus} out=#{out.strip.inspect} err=#{err.strip.inspect}"
        end
      rescue StandardError
        nil
      end

      def log_orphan_sweep_warning(task, message)
        log_path = orphan_sweep_log_path(task)
        rotate_orphan_sweep_log(log_path)
        File.open(log_path, "a") { |f| f.puts "[#{Time.now.utc.iso8601}] WARN: #{message}" }
      rescue StandardError
        nil
      end

      def orphan_sweep_log_path(task)
        File.join(task.folder, "brainstorm-tmux-orphan-sweep.log")
      end

      # Cap the log file at `ORPHAN_SWEEP_LOG_MAX_BYTES`. The stage
      # folder is meant to be ephemeral, but repeated reruns of the same
      # slug accumulate this log indefinitely otherwise. On overflow we
      # truncate rather than rotate — the file is forensic, and the most
      # recent sweep is what matters.
      def rotate_orphan_sweep_log(log_path)
        return unless File.exist?(log_path)
        return if File.size(log_path) < ORPHAN_SWEEP_LOG_MAX_BYTES

        File.write(log_path, "[#{Time.now.utc.iso8601}] (log truncated, prior contents exceeded #{ORPHAN_SWEEP_LOG_MAX_BYTES} bytes)\n")
      rescue StandardError
        nil
      end

      def cleanup_done(task)
        path = done_path(task)
        File.delete(path) if File.exist?(path)
      end

      # Idempotent teardown of the per-task scratch settings. Rescue
      # widened to cover read-only/perms-locked mounts (`EACCES`/`EROFS`)
      # so a failure here can't bubble up after `kill_session` has run
      # and leave the scratch behind — `cleanup_scratch` is defensive
      # cleanup, never a hard requirement.
      def cleanup_scratch(settings_path)
        return unless settings_path

        File.delete(settings_path) if File.exist?(settings_path)
        dir = File.dirname(settings_path)
        Dir.rmdir(dir) if Dir.exist?(dir) && Dir.empty?(dir)
      rescue Errno::ENOENT, Errno::ENOTEMPTY, Errno::EACCES, Errno::EROFS, Errno::EPERM
        nil
      end

      def done_path(task)
        File.join(task.folder, ".done")
      end

      def result_path(task)
        File.join(task.folder, "result.json")
      end
    end
  end
end
