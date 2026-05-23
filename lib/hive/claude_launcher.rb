require "fileutils"
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
    CLAUDE_READY_WAIT_TIMEOUT_SEC = 30
    CLAUDE_READY_POLL_INTERVAL_SEC = 0.25
    MIN_TMUX_VERSION = "3.0"
    TERMINAL_MARKERS = %i[waiting complete error execute_complete review_complete review_waiting review_error].freeze
    DEFAULT_ALLOWED_TOOLS = "Read,Write,Edit,LS".freeze
    DEFAULT_PERMISSION_MODE = "bypassPermissions".freeze

    ORPHAN_SWEEP_LOG_MAX_BYTES = 64 * 1024
    TMUX_UNAVAILABLE_PATTERNS = [
      /tmux not runnable/,
      /tmux binary not runnable/,
      /could not parse tmux -V output/,
      /tmux \S+ below minimum/,
      /tmux session .* did not start/
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
      preflight!(profile, runner)

      settings_path = nil
      begin
        settings_path = Hive::StopHookInstaller.install(stage_dir: task.folder)
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
        safe { runner.kill_session if runner }
        safe { sweep_orphan_processes(task) }
        safe { cleanup_scratch(settings_path) }
        safe { cleanup_done(task) }
      end
    end

    def send_prompt_and_wait!(task:, runner:, prompt:, timeout_sec:,
                              expected_output: nil, status_mode: nil,
                              log_label: nil)
      reset_signal_files(task)
      cleanup_expected_output(expected_output)
      prepare_claude_session!(runner)
      runner.send_prompt(prompt)
      wait_for_status(task, runner, timeout_sec, status_mode, expected_output, log_label)
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
      "hive-#{stage_short_name}-#{task_slug(task)}"[0, 250]
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
    rescue Hive::TmuxError
      nil
    end

    def prepare_claude_session!(runner)
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

    def wait_for_expected_output(task, runner, timeout, expected_output, log_label)
      deadline = Time.now + timeout
      loop do
        if File.exist?(expected_output.to_s) && File.size(expected_output.to_s).positive?
          return { status: :ok, log_label: log_label } if File.exist?(done_path(task))

          begin
            pane = runner.capture_pane_tail(bytes: SENTINEL_CAPTURE_BYTES)
            return { status: :ok, log_label: log_label } if claude_ready_prompt?(pane)
          rescue Hive::TmuxError
            nil
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
        return { status: :ok, log_label: log_label } if File.exist?(done_path(task))

        if Time.now >= deadline
          return { status: :timeout, error_message: "claude stop hook did not signal completion" }
        end

        sleep [ poll_interval, deadline - Time.now ].min
      end
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
    rescue Errno::ENOENT
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
    rescue StandardError
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
    rescue Errno::ENOENT, Errno::ENOTEMPTY, Errno::EACCES, Errno::EROFS, Errno::EPERM
      nil
    end

    def done_path(task)
      File.join(task.folder, ".done")
    end

    def result_path(task)
      File.join(task.folder, "result.json")
    end

    def safe
      yield
    rescue StandardError
      nil
    end
  end
end
