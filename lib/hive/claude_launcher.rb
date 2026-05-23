require "fileutils"
require "json"
require "open3"
require "time"

require "hive/agent_profiles"
require "hive/config"
require "hive/lock"
require "hive/markers"
require "hive/stop_hook_installer"
require "hive/tmux_runner"

module Hive
  module ClaudeLauncher
    READY_WAIT_TIMEOUT_SEC = 5
    DONE_POLL_INTERVAL_SEC = 0.5
    SENTINEL_POLL_INTERVAL_SEC = 5
    SENTINEL_CAPTURE_BYTES = 8192
    PANE_LOG_CAPTURE_BYTES = 64 * 1024
    # Shared-session reviewer sends re-call `prepare_claude_session!`
    # between each per-reviewer prompt; a 30s ceiling was too tight for
    # the legitimate case where the prior reviewer's response was still
    # streaming when the next send arrived (a reviewer with the default
    # 600s timeout can run minutes; the pane is busy-not-crashed). Bump
    # to 120s so a slow-streaming-but-alive pane is treated as busy
    # rather than crashed; an actually-dead session still surfaces
    # quickly via the explicit `session_exists?` precheck.
    CLAUDE_READY_WAIT_TIMEOUT_SEC = 120
    CLAUDE_READY_POLL_INTERVAL_SEC = 0.25
    MIN_TMUX_VERSION = "3.0"
    TERMINAL_MARKERS = %i[waiting complete error execute_complete review_complete review_waiting review_error].freeze
    # Allowed-tool sets shared by every stage that spawns Claude. Keeping
    # them as constants means a policy change lands in one place; previous
    # PRs inlined the string literal across 11 sites and silently drifted
    # when one of them was updated without the others. R4 in the plan
    # called out the implementer/planner split — keep them separate.
    PLANNER_ALLOWED_TOOLS = "Read,Write,Edit,LS".freeze
    IMPLEMENTER_ALLOWED_TOOLS = "Read,Write,Edit,Bash,LS,Glob,Grep".freeze
    DEFAULT_ALLOWED_TOOLS = PLANNER_ALLOWED_TOOLS
    DEFAULT_PERMISSION_MODE = "bypassPermissions".freeze

    ORPHAN_SWEEP_LOG_MAX_BYTES = 64 * 1024
    # Patterns that mark tmux itself as unavailable (binary missing, too
    # old, unparseable). A session-startup TIMEOUT (`tmux session … did
    # not start`) is intentionally NOT in this list — that's a transient
    # tmux-is-present-but-slow failure, not "tmux missing", and routing
    # it through the hard-fail tmux_unavailable path would masquerade a
    # transient as an unrecoverable configuration error.
    # Anchored regexes pin the exact `preflight_tmux!` error prefixes
    # that classify as "tmux is missing/unrunnable" (as opposed to
    # transient per-session failures, which are intentionally NOT in
    # this list). The patterns match the literal message heads emitted
    # by `preflight_tmux!`; a "tidying" refactor that broadens these
    # (e.g. matching `tmux .* runnable` for a hypothetical "tmux
    # runnable check failed" message) would silently route transients
    # through the hard-fail path. The `\Atmux \S+ below minimum`
    # pattern matches "tmux 2.9 below minimum 3.0" exactly. Update
    # `preflight_tmux!` and this list together.
    TMUX_UNAVAILABLE_PATTERNS = [
      /\Atmux not runnable:/,
      /\Atmux binary not runnable:/,
      /\Acould not parse tmux -V output:/,
      /\Atmux \S+ below minimum/
    ].freeze

    SessionHandle = Struct.new(:task, :runner, keyword_init: true) do
      def send_and_wait!(prompt:, expected_output: nil, timeout_sec:,
                         status_mode: nil, log_label: nil)
        Hive::ClaudeLauncher.send_prompt_and_wait!(
          task: task,
          runner: runner,
          prompt: prompt,
          expected_output: expected_output,
          timeout_sec: timeout_sec,
          status_mode: status_mode,
          log_label: log_label
        )
      end
    end

    module_function

    def launch!(task:, cfg:, prompt:, add_dirs:, cwd:, max_budget_usd:,
                timeout_sec:, log_label:, session_name:, status_mode: nil,
                expected_output: nil, profile: nil,
                allowed_tools: DEFAULT_ALLOWED_TOOLS,
                permission_mode: DEFAULT_PERMISSION_MODE)
      profile ||= Hive::AgentProfiles.lookup(:claude, cfg: cfg)
      ensure_claude_profile!(profile)

      if Hive::Config.claude_mode(cfg) == :headless
        require "hive/stages/base"
        return Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: add_dirs,
          cwd: cwd,
          max_budget_usd: max_budget_usd,
          timeout_sec: timeout_sec,
          log_label: log_label,
          profile: profile,
          expected_output: expected_output,
          status_mode: status_mode
        )
      end

      result = nil
      with_shared_session(
        task: task,
        cfg: cfg,
        session_name: session_name,
        cwd: cwd,
        add_dirs: add_dirs,
        profile: profile,
        allowed_tools: allowed_tools,
        permission_mode: permission_mode
      ) do |handle|
        result = handle.send_and_wait!(
          prompt: prompt,
          expected_output: expected_output,
          timeout_sec: timeout_sec,
          status_mode: status_mode || profile.status_detection_mode,
          log_label: log_label
        )
      end
      result
    end

    def with_shared_session(task:, cfg:, session_name:, cwd:, add_dirs:,
                            profile: nil, allowed_tools: DEFAULT_ALLOWED_TOOLS,
                            permission_mode: DEFAULT_PERMISSION_MODE)
      profile ||= Hive::AgentProfiles.lookup(:claude, cfg: cfg)
      ensure_claude_profile!(profile)

      runner = build_runner(task: task, session_name: session_name, cwd: cwd)
      # Pre-clean signal files BEFORE the preflight check so a stale
      # `.done` / `result.json` from a previously-collided run doesn't
      # leak into the next attempt's wait_for_status loop. A
      # session-collision raise out of `preflight!` would otherwise leave
      # the prior task's signal files in place (this block runs before
      # the inner `begin/ensure`, where the cleanup_done sat previously).
      safe_with_log(task, "reset_signal_files") { reset_signal_files(task) }
      preflight!(profile, runner)

      settings_paths = []
      begin
        # Install the Stop hook under task.folder (orchestrator-owned)
        # AND the launch cwd. Claude resolves `.claude/settings.json`
        # from the process cwd, not from --add-dir paths; stages whose
        # cwd is the feature worktree (4-execute / 6-review) otherwise
        # never produced .done / result.json and downstream waits hung
        # until timeout.
        settings_paths = Array(Hive::StopHookInstaller.install(
          stage_dir: task.folder,
          extra_dirs: [ cwd ]
        ))
        runner.start_detached(
          command: wrapper_command(
            cwd: cwd,
            add_dirs: add_dirs,
            profile: profile,
            allowed_tools: allowed_tools,
            permission_mode: permission_mode
          )
        )
        wait_until_session_exists!(runner)
        record_claude_pid(task, runner)
        prepare_claude_session!(runner)
        yield SessionHandle.new(task: task, runner: runner)
      ensure
        # Send `/quit` to claude inside the pane and give it a brief
        # window to exit cleanly before SIGKILL'ing the tmux session.
        # Previously the session was torn down with `kill-session`
        # alone, so claude received SIGKILL and never wrote its session
        # rollup. The grace window is short enough not to block real
        # error paths; the hard `kill_session` below is the backstop.
        safe_with_log(task, "shutdown_claude") { shutdown_claude(runner) }
        safe_with_log(task, "kill_session") { runner.kill_session if runner }
        safe_with_log(task, "sweep_orphan_processes") { sweep_orphan_processes(task) }
        Array(settings_paths).each do |path|
          safe_with_log(task, "cleanup_scratch") { cleanup_scratch(path) }
        end
        safe_with_log(task, "cleanup_done") { cleanup_done(task) }
      end
    end

    def send_prompt_and_wait!(task:, runner:, prompt:, timeout_sec:,
                              expected_output: nil, status_mode: nil,
                              log_label: nil)
      reset_signal_files(task)
      cleanup_expected_output(expected_output)
      prepare_claude_session!(runner)
      effective_mode = status_mode || :state_file_marker
      # Parity with `Hive::Agent#run!`: only the :state_file_marker mode
      # stamps the AGENT_WORKING transient marker (the orchestrator
      # owns the marker for the other modes). Without this, `hive
      # status`, the TUI, and daemon recovery lose the in-progress
      # marker required by ADR-005 while a tmux-mode spawn is alive.
      if effective_mode == :state_file_marker
        Hive::Markers.set(task.state_file, :agent_working,
                          pid: Process.pid,
                          started: Time.now.utc.iso8601)
      end
      runner.send_prompt(prompt)
      result = wait_for_status(task, runner, timeout_sec, status_mode, expected_output, log_label)
      # Headless launches drop a `<log_label>-<ts>.log` under
      # `task.log_dir`; tmux launches need the same shared log path so
      # downstream Claude-driven stages can find per-invocation output.
      capture_pane_log(task, runner, log_label)
      augment_result_with_final_message!(result, runner)
      result
    end

    # Headless agents return `{final_message:, final_message_source:,
    # ...}`; tmux mode previously returned only `{status:, log_label:}`
    # which broke every caller that read `final_message` (4-execute's
    # research-mode check, append_implementation_output, …). Capture
    # the pane tail as a `:plain` final_message so the contract is the
    # same regardless of mode. Source stays `:plain` because a tmux
    # pane is unstructured terminal output, not the headless JSON
    # stream that Agent extracts `:structured` from.
    def augment_result_with_final_message!(result, runner)
      return result unless result.is_a?(Hash)
      return result if result.key?(:final_message) || result.key?(:final_message_source)

      tail = safe_pane_tail(runner, bytes: PANE_LOG_CAPTURE_BYTES).to_s.strip
      if tail.empty?
        result[:final_message] = nil
        result[:final_message_source] = nil
      else
        result[:final_message] = tail
        result[:final_message_source] = :plain
      end
      result
    end

    def safe_pane_tail(runner, bytes:)
      return "" unless runner

      runner.capture_pane_tail(bytes: bytes)
    rescue Hive::TmuxError
      ""
    end

    # Append the current pane tail to `<task.log_dir>/<log_label>-<ts>.log`
    # so tmux-mode runs leave a discoverable per-invocation log next to
    # the headless agent's. Best-effort — a log-write failure must not
    # alter the spawn's result envelope.
    def capture_pane_log(task, runner, log_label)
      return unless log_label && task && runner
      return unless task.respond_to?(:log_dir)

      pane = runner.capture_pane_tail(bytes: PANE_LOG_CAPTURE_BYTES)
      FileUtils.mkdir_p(task.log_dir)
      ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      File.open(File.join(task.log_dir, "#{log_label}-#{ts}.log"), "a") do |f|
        f.puts pane
      end
    rescue StandardError => e
      warn "[hive] could not write tmux pane log for #{log_label}: #{e.class}: #{e.message}"
      nil
    end

    def wait_for_status(task, runner, timeout, status_mode, expected_output, log_label)
      case status_mode || :state_file_marker
      when :state_file_marker
        marker = wait_for_terminal_marker(task, runner, timeout)
        { status: marker.name, log_label: log_label }
      when :output_file_exists
        wait_for_expected_output(task, runner, timeout, expected_output, log_label)
      when :exit_code_only
        wait_for_done_signal(task, runner, timeout, log_label)
      else
        raise ArgumentError, "unknown status_mode: #{status_mode.inspect}"
      end
    end

    def ensure_claude_profile!(profile)
      return if profile.name == :claude

      raise Hive::AgentError, "ClaudeLauncher only supports the claude profile; got #{profile.name.inspect}"
    end

    def tmux_session_name(stage_short_name, task)
      # Byte-slice (not char-slice) — a multi-byte slug would otherwise
      # produce a session name longer than 250 bytes after String#[]
      # picks codepoints. Tail-truncated mid-codepoint scrubbing avoids
      # surfacing invalid UTF-8 downstream; collisions between two long
      # slugs that share a 250-byte prefix are an explicit operator
      # responsibility.
      raw = "hive-#{stage_short_name}-#{task_slug(task)}"
      sliced = raw.byteslice(0, 250).to_s
      sliced.force_encoding(Encoding::UTF_8).scrub("")
    end

    def task_slug(task)
      return task.slug if task.respond_to?(:slug) && task.slug

      File.basename(task.folder.to_s)
    end

    def build_runner(task:, session_name:, cwd:)
      Hive::TmuxRunner.new(
        name: session_name,
        cwd: cwd,
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

    def tmux_status(tmux_bin: self.tmux_bin)
      version = preflight_tmux!(tmux_bin: tmux_bin)
      [ :present, "tmux #{version} found" ]
    rescue Hive::AgentError => e
      status = e.message.include?("below minimum") ? :version_too_old : :missing
      [ status, e.message ]
    end

    def tmux_unavailable_error?(error)
      return false unless error.is_a?(Hive::AgentError)

      message = error.message.to_s
      TMUX_UNAVAILABLE_PATTERNS.any? { |pattern| message.match?(pattern) }
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

    def wrapper_command(cwd:, add_dirs:, profile:, allowed_tools: DEFAULT_ALLOWED_TOOLS,
                        permission_mode: DEFAULT_PERMISSION_MODE)
      command = [
        "bash",
        File.expand_path("scripts/interactive_claude_wrapper.sh", __dir__),
        "--cwd", cwd
      ]
      Array(add_dirs).each { |dir| command.concat([ "--add-dir", dir ]) }
      command.concat([
        "--permission-mode", permission_mode,
        "--allowedTools", allowed_tools,
        "--bin", profile.bin
      ])
      command
    end

    def wait_until_session_exists!(runner)
      deadline = Time.now + session_ready_wait_timeout
      until runner.session_exists?
        raise Hive::AgentError, "tmux session #{runner.name} did not start" if Time.now >= deadline

        sleep 0.1
      end
    end

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
    rescue Hive::TmuxError => e
      # Losing the pid means `hive lock` can no longer kill claude
      # cleanly; warn so an operator running interactively sees the
      # signal instead of discovering it later via a stuck process.
      warn "[hive] failed to capture claude pane pid for #{File.basename(task.folder.to_s)}: #{e.message}"
      nil
    end

    def prepare_claude_session!(runner)
      # Distinguish "session was alive, claude inside it died" from
      # "trust prompt never appeared" — both look like "last_tail
      # didn't show the ready prompt" by the deadline, but a dead
      # session is unrecoverable (the operator must start a new
      # claude) while a slow trust prompt usually just needs more time.
      unless runner.respond_to?(:session_exists?) && runner.session_exists?
        # The test FakeInteractiveRunner used in unit tests does not
        # implement `session_exists?`; only enforce when available.
        if runner.respond_to?(:session_exists?)
          raise Hive::AgentError,
                "claude tmux session #{runner.name} terminated before becoming ready " \
                "(session no longer exists)"
        end
      end

      deadline = Time.now + claude_ready_wait_timeout
      last_tail = ""
      loop do
        last_tail = runner.capture_pane_tail(bytes: SENTINEL_CAPTURE_BYTES)

        if claude_trust_prompt?(last_tail)
          runner.send_keys("Enter")
          sleep CLAUDE_READY_POLL_INTERVAL_SEC
          break if Time.now >= deadline
          next
        end

        return true if claude_ready_prompt?(last_tail)

        break if Time.now >= deadline

        sleep CLAUDE_READY_POLL_INTERVAL_SEC
      end

      raise Hive::AgentError,
            "claude interactive prompt did not become ready in tmux session #{runner.name}; " \
            "last pane tail: #{last_tail.byteslice(-500, 500).to_s.scrub.inspect}"
    rescue Hive::TmuxError => e
      raise Hive::AgentError, "could not inspect claude tmux session #{runner.name}: #{e.message}"
    end

    def claude_trust_prompt?(pane)
      pane.include?("Quick safety check") && pane.include?("Yes, I trust this folder")
    end

    def claude_ready_prompt?(pane)
      return false if claude_trust_prompt?(pane)
      return false if pane.include?("Do you want to")

      pane.include?("Claude Code") && pane.include?("❯")
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
          existing = Hive::Markers.current(task.state_file)
          # When `marker_from_sentinel_tail` already stamped
          # `:error reason="tmux_pane_unreadable"` (its terminal-
          # marker contract: write attribution then return nil so the
          # outer loop can keep polling), overwriting with a generic
          # `reason="timeout"` would mask the real root cause. Preserve
          # the existing attribution and bail.
          if existing.name == :error && existing.attrs["reason"] == "tmux_pane_unreadable"
            return existing
          end

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
    rescue Hive::TmuxError => e
      # A persistent tmux failure mid-wait used to silently roll into
      # the outer timeout and surface as `:error reason="timeout"`.
      # Stamp an attributed marker so the operator sees the real cause
      # before the polling loop reaches the deadline; let the next
      # iteration re-read it.
      Hive::Markers.set(task.state_file, :error,
                        reason: "tmux_pane_unreadable",
                        message: e.message)
      nil
    end

    def wait_for_expected_output(task, runner, timeout, expected_output, log_label)
      deadline = Time.now + timeout
      tmux_error_streak = 0
      last_tmux_error_msg = nil
      loop do
        if File.exist?(expected_output.to_s) && File.size(expected_output.to_s).positive?
          return { status: :ok, log_label: log_label } if File.exist?(done_path(task))

          begin
            pane = runner.capture_pane_tail(bytes: SENTINEL_CAPTURE_BYTES)
            tmux_error_streak = 0
            return { status: :ok, log_label: log_label } if claude_ready_prompt?(pane)
          rescue Hive::TmuxError => e
            tmux_error_streak += 1
            last_tmux_error_msg = e.message
            # After a handful of consecutive failures, the pane is
            # demonstrably unreachable; bail with the real cause
            # instead of polling silently to deadline and reporting
            # a misleading "expected output file missing" timeout.
            if tmux_error_streak >= 3
              return {
                status: :error,
                error_message: "tmux_pane_unreadable: #{last_tmux_error_msg}"
              }
            end
          end
        end

        if Time.now >= deadline
          return {
            status: :timeout,
            error_message: "expected output file missing or empty: #{expected_output}"
          }
        end

        sleep [ poll_interval, deadline - Time.now ].min
      end
    end

    def wait_for_done_signal(task, _runner, timeout, log_label)
      deadline = Time.now + timeout
      loop do
        if File.exist?(done_path(task))
          # The stop-hook touches `.done` even on `empty_stdin` /
          # other non-success completions; the real status lives in
          # `result.json`. Without this check, an exit_code_only
          # caller (e.g. the Phase 4 fix agent) would see `:ok` for
          # an errored claude run.
          status = read_result_json_status(task)
          if status == :ok
            return { status: :ok, log_label: log_label }
          elsif status
            return { status: status, log_label: log_label,
                     error_message: "claude reported #{status.inspect} via result.json" }
          end
          # No result.json on disk yet — the .done write may have
          # raced the result write. Treat as completion since
          # exit_code_only callers don't carry a richer contract.
          return { status: :ok, log_label: log_label }
        end

        if Time.now >= deadline
          return { status: :timeout, error_message: "claude stop hook did not signal completion" }
        end

        sleep [ poll_interval, deadline - Time.now ].min
      end
    end

    # Read `result.json` (if present) and translate `status` into the
    # caller's symbol vocabulary. Unknown / unparseable shapes return
    # nil so the caller can fall through to its default success path.
    def read_result_json_status(task)
      path = result_path(task)
      return nil unless File.exist?(path) && File.size(path).positive?

      data = JSON.parse(File.read(path))
      return nil unless data.is_a?(Hash)

      raw = data["status"].to_s
      case raw
      when "ok", "complete", "success" then :ok
      when "" then nil
      else raw.to_sym
      end
    rescue JSON::ParserError, SystemCallError, IOError
      nil
    end

    def poll_interval
      Float(tmux_env("POLL_INTERVAL_SEC", DONE_POLL_INTERVAL_SEC.to_s))
    end

    def sentinel_poll_interval
      Float(tmux_env("SENTINEL_INTERVAL_SEC", SENTINEL_POLL_INTERVAL_SEC.to_s))
    end

    def ready_wait_timeout
      Float(tmux_env("READY_WAIT_TIMEOUT_SEC", READY_WAIT_TIMEOUT_SEC.to_s))
    end

    def claude_ready_wait_timeout
      Float(tmux_env("CLAUDE_READY_WAIT_TIMEOUT_SEC", CLAUDE_READY_WAIT_TIMEOUT_SEC.to_s))
    end

    def session_ready_wait_timeout
      Float(tmux_env("SESSION_READY_WAIT_TIMEOUT_SEC", ready_wait_timeout.to_s))
    end

    def pid_ready_wait_timeout
      Float(tmux_env("PID_READY_WAIT_TIMEOUT_SEC", ready_wait_timeout.to_s))
    end

    def tmux_env(name, default)
      ENV.fetch("HIVE_CLAUDE_TMUX_#{name}") do
        ENV.fetch("HIVE_BRAINSTORM_TMUX_#{name}", default)
      end
    end

    def reset_signal_files(task)
      cleanup_done(task)
      result = result_path(task)
      File.delete(result) if File.exist?(result)
    rescue Errno::ENOENT
      # TOCTOU: another process can unlink the file between the
      # `File.exist?` check above and the `File.delete`. Treat that as
      # the no-op outcome — the file is gone, which is what we wanted.
      nil
    end

    def cleanup_expected_output(expected_output)
      return if expected_output.nil? || expected_output.to_s.empty?

      File.delete(expected_output) if File.exist?(expected_output)
    rescue Errno::ENOENT
      nil
    end

    def sweep_orphan_processes(task)
      pattern = orphan_sweep_pattern(task)
      matches, pgrep_err, pgrep_status = Open3.capture3("pgrep", "-fa", "--", pattern)
      if !pgrep_status.success? && pgrep_status.exitstatus != 1
        log_orphan_sweep_warning(task, "pgrep failed: exit=#{pgrep_status.exitstatus} err=#{pgrep_err.strip.inspect}")
        return
      end
      return if matches.strip.empty?

      out, err, status = Open3.capture3("pkill", "-f", "--", pattern)
      log_orphan_sweep(task, matches, out, err, status)
    rescue Errno::ENOENT => e
      # `pgrep` / `pkill` not installed on this host. The blanket
      # rescue used to swallow this silently, disabling orphan cleanup
      # with zero operator signal. Surface a warning so the missing
      # binary is visible without breaking the spawn.
      log_orphan_sweep_warning(task,
                               "pgrep/pkill missing: #{e.message}; orphan cleanup disabled for this run")
      nil
    end

    def orphan_sweep_pattern(task)
      "--add-dir[[:space:]]+#{Regexp.escape(task.folder)}([[:space:]]|$)"
    end

    def log_orphan_sweep(task, matches, out, err, status)
      log_path = orphan_sweep_log_path(task)
      rotate_orphan_sweep_log(log_path)
      File.open(log_path, "a") do |f|
        f.puts "[#{Time.now.utc.iso8601}] pgrep matches:"
        f.puts matches
        f.puts "[#{Time.now.utc.iso8601}] pkill exit=#{status&.exitstatus} " \
               "out=#{out.strip.inspect} err=#{err.strip.inspect}"
      end
    rescue StandardError => e
      # Full disk / EROFS / EACCES: don't swallow silently — the
      # operator may need to know the sweep ran but couldn't record
      # its log. Fall back to stderr so the signal isn't lost.
      warn "[hive] could not write orphan-sweep log #{log_path}: #{e.message}"
      nil
    end

    def log_orphan_sweep_warning(task, message)
      log_path = orphan_sweep_log_path(task)
      rotate_orphan_sweep_log(log_path)
      File.open(log_path, "a") { |f| f.puts "[#{Time.now.utc.iso8601}] WARN: #{message}" }
    rescue StandardError => e
      warn "[hive] could not write orphan-sweep log #{log_path}: #{e.message}"
      warn "[hive] (original warning): #{message}"
      nil
    end

    def orphan_sweep_log_path(task)
      File.join(task.folder, "claude-tmux-orphan-sweep.log")
    end

    def rotate_orphan_sweep_log(log_path)
      return unless File.exist?(log_path)
      return if File.size(log_path) < ORPHAN_SWEEP_LOG_MAX_BYTES

      File.write(
        log_path,
        "[#{Time.now.utc.iso8601}] " \
        "(log truncated, prior contents exceeded #{ORPHAN_SWEEP_LOG_MAX_BYTES} bytes)\n"
      )
    rescue StandardError => e
      warn "[hive] could not rotate orphan-sweep log #{log_path}: #{e.message}"
      nil
    end

    def cleanup_done(task)
      path = done_path(task)
      File.delete(path) if File.exist?(path)
    end

    def cleanup_scratch(settings_path)
      return unless settings_path

      File.delete(settings_path) if File.exist?(settings_path)
      dir = File.dirname(settings_path)
      Dir.rmdir(dir) if Dir.exist?(dir) && Dir.empty?(dir)
    rescue Errno::ENOENT, Errno::ENOTEMPTY
      nil
    rescue Errno::EACCES, Errno::EROFS, Errno::EPERM => e
      # Stale settings.json from a previous run owned by another user
      # (e.g., a sudo invocation that left root-owned scratch files)
      # would silently persist and confuse the next spawn. Surface so
      # the operator knows the cleanup didn't land.
      warn "[hive] could not remove tmux-scratch settings #{settings_path}: #{e.class}: #{e.message}"
      nil
    end

    def done_path(task)
      File.join(task.folder, ".done")
    end

    def result_path(task)
      File.join(task.folder, "result.json")
    end

    # Like the (removed) bare `safe` helper, but logs the swallowed
    # sees cleanup failures (orphan tmux sessions, stale settings.json)
    # instead of discovering them on the next preflight collision.
    def safe_with_log(task, step)
      yield
    rescue StandardError => e
      warn "[hive] tmux cleanup step #{step.inspect} failed for " \
           "#{task && task.folder ? File.basename(task.folder.to_s) : '(unknown task)'}: " \
           "#{e.class}: #{e.message}"
      nil
    end

    # Best-effort claude shutdown: type `/quit`, send Enter, and give
    # claude a brief window to flush its session rollup before the
    # tmux session is killed.
    def shutdown_claude(runner)
      return unless runner
      return if runner.respond_to?(:session_exists?) && !runner.session_exists?

      runner.send_prompt("/quit") if runner.respond_to?(:send_prompt)
      sleep claude_shutdown_grace
    end

    def claude_shutdown_grace
      Float(tmux_env("SHUTDOWN_GRACE_SEC", "0.5"))
    end
  end
end
