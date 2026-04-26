require "fileutils"
require "json"
require "open3"
require "time"
require "hive/agent_profiles"
require "hive/lock"

module Hive
  class Agent
    attr_reader :task, :prompt, :add_dirs, :cwd, :max_budget_usd, :timeout_sec,
                :profile, :expected_output, :status_mode

    def initialize(task:, prompt:, max_budget_usd:, timeout_sec:,
                   add_dirs: [], cwd: nil, log_label: nil,
                   profile: nil, expected_output: nil, status_mode: nil)
      @task = task
      @prompt = prompt
      @add_dirs = Array(add_dirs)
      @cwd = cwd || task.folder
      @max_budget_usd = max_budget_usd
      @timeout_sec = timeout_sec
      @log_label = log_label || task.stage_name
      @profile = profile || Hive::AgentProfiles.lookup(:claude)
      @expected_output = expected_output
      # Per-spawn override of the profile's default detection mode. The
      # same CLI (e.g., claude) serves multiple roles — 4-execute uses
      # :state_file_marker (agent writes terminal marker to task.md);
      # the 5-review reviewer adapter uses :output_file_exists (agent
      # writes a structured findings file). Passing nil falls back to
      # the profile's default. Validation lives in AgentProfile's enum.
      if status_mode && !Hive::AgentProfile::STATUS_DETECTION_MODES.include?(status_mode)
        raise ArgumentError,
              "unknown status_mode: #{status_mode.inspect}; valid: #{Hive::AgentProfile::STATUS_DETECTION_MODES.inspect}"
      end
      @status_mode = status_mode
    end

    # Effective mode for this spawn — explicit kwarg wins, falls back to
    # the profile's default.
    def effective_status_mode
      @status_mode || @profile.status_detection_mode
    end

    # Backward-compat class methods. Resolve to the claude profile so legacy
    # call sites (Hive::Agent.bin, Hive::Agent.check_version!) keep working.
    #
    # Caveat (correctness finding #11): these methods bypass per-spawn
    # profile selection and ALWAYS resolve to the claude profile —
    # misleading on a project running codex/pi. Pass an explicit
    # profile: kwarg into Hive::Stages::Base.spawn_agent or call
    # `Hive::AgentProfiles.lookup(:codex).bin` / `.check_version!`
    # directly when the agent isn't claude. The methods are retained
    # as smoke-test / fixture conveniences only.
    def self.bin
      maybe_warn_legacy_class_method(:bin)
      Hive::AgentProfiles.lookup(:claude).bin
    end

    def self.check_version!
      maybe_warn_legacy_class_method(:check_version!)
      Hive::AgentProfiles.lookup(:claude).check_version!
    end

    # Emit a one-shot deprecation warning the first time either legacy
    # class method is called from outside the test suite. Suppress in
    # tests so the existing assertion suite (which exercises the
    # backward-compat shim by design) doesn't churn captured stderr.
    @legacy_warned = {}
    def self.maybe_warn_legacy_class_method(name)
      return if ENV["HIVE_TEST"] == "1"
      return if defined?(Minitest)
      return if @legacy_warned[name]

      @legacy_warned[name] = true
      warn "Hive::Agent.#{name} is claude-specific and ignores AgentProfile " \
           "selection; pass profile: explicitly or use AgentProfiles.lookup(:<name>).#{name}"
    end

    def run!
      ensure_log_dir
      # Marker writes on task.state_file are gated by the profile's
      # status_detection_mode. Only the :state_file_marker mode (today's
      # claude path for 4-execute / brainstorm / plan / pr) writes
      # :agent_working pre-spawn — the agent itself overwrites it with
      # the terminal marker on exit. The other two modes do NOT write
      # the task marker because the orchestrator owns it (e.g., the
      # 5-review runner sets REVIEW_WORKING phase=reviewers and that
      # must persist across each per-reviewer spawn).
      if effective_status_mode == :state_file_marker
        Hive::Markers.set(@task.state_file, :agent_working,
                          pid: Process.pid,
                          started: Time.now.utc.iso8601)
      end
      result = spawn_and_wait
      handle_exit(result)
      result
    end

    def spawn_and_wait
      cmd = build_cmd
      log_file = log_path
      File.open(log_file, "a") do |log|
        log.puts "[hive] #{Time.now.utc.iso8601} spawn cwd=#{@cwd} cmd=#{cmd.inspect}"
      end
      r, w = IO.pipe
      pid = Process.spawn(*cmd, chdir: @cwd, pgroup: true, out: w, err: w)
      w.close
      pgid = begin
        Process.getpgid(pid)
      rescue Errno::ESRCH
        pid
      end

      Hive::Lock.update_task_lock(@task.folder, "claude_pid" => pid)

      old_int = trap("INT") { kill_group(pgid) }
      old_term = trap("TERM") { kill_group(pgid) }

      reader = Thread.new do
        File.open(log_file, "a") do |log|
          r.each_line do |line|
            log.write("[stream] #{Time.now.utc.iso8601} #{line}")
            log.write("\n") unless line.end_with?("\n")
            log.flush
          end
        end
      ensure
        r.close unless r.closed?
      end
      # Surface reader-thread crashes (ENOSPC on log, encoding errors, etc.)
      # instead of letting them die silently — a dead reader can stall the
      # child once the pipe buffer fills.
      reader.report_on_exception = true

      timed_out = false
      deadline = Time.now + @timeout_sec
      status = nil
      begin
        loop do
          remaining = deadline - Time.now
          if remaining <= 0
            timed_out = true
            kill_group(pgid)
            break
          end
          # Capture status atomically into a local; avoids races on $? / $CHILD_STATUS
          # being clobbered by other Process.wait calls (e.g. from the reader thread).
          captured = Process.wait2(pid, Process::WNOHANG)
          if captured
            status = captured.last
            break
          end
          sleep [ remaining, 0.2 ].min
        end
      ensure
        trap("INT", old_int || "DEFAULT")
        trap("TERM", old_term || "DEFAULT")
      end

      if timed_out
        sleep_grace_then_kill(pgid, pid)
        status = begin
          Process.wait2(pid).last
        rescue StandardError
          nil
        end
      end
      reader.join(2)
      reader.kill if reader.alive?

      exit_code = if status.nil?
                    nil
      elsif status.exited?
                    status.exitstatus
      elsif status.signaled?
                    -status.termsig
      end

      {
        pid: pid,
        pgid: pgid,
        exit_code: exit_code,
        timed_out: timed_out,
        log_file: log_file,
        status: nil
      }
    end

    # Build the argv for the configured profile.
    #
    # Order is fixed:
    #   bin, headless_flag, permission_skip_flag (if any),
    #   --add-dir <dir> repeated for each add_dir (if profile supports),
    #   budget_flag <amount> (if profile supports),
    #   output_format_flags...,
    #   extra_flags...,
    #   prompt
    #
    # The claude profile reproduces today's hardcoded argv exactly (verified
    # by test/unit/agent_test.rb#test_args_include_dangerous_flag_and_add_dir
    # and #test_argv_includes_verbose_when_stream_json which still pass after
    # the refactor — the claude profile's flag set IS today's flag set).
    def build_cmd
      cmd = [ @profile.bin ]
      cmd << @profile.headless_flag if @profile.headless_flag
      cmd << @profile.permission_skip_flag if @profile.permission_skip_flag
      if @profile.add_dir_flag
        @add_dirs.each do |d|
          cmd << @profile.add_dir_flag << d
        end
      end
      if @profile.budget_flag && @max_budget_usd
        cmd << @profile.budget_flag << @max_budget_usd.to_s
      end
      cmd.concat(@profile.output_format_flags)
      cmd << @prompt
      cmd
    end

    def kill_group(pgid)
      Process.kill("TERM", -pgid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def sleep_grace_then_kill(pgid, pid)
      grace_deadline = Time.now + 3
      until Time.now >= grace_deadline
        return if Process.wait(pid, Process::WNOHANG)

        sleep 0.2
      end
      begin
        Process.kill("KILL", -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    rescue Errno::ECHILD
      nil
    end

    # Determine result[:status] from exit_code + profile.status_detection_mode.
    #
    # - :state_file_marker  — read marker from task.state_file (today's
    #   claude behavior; the agent writes its terminal marker itself).
    # - :exit_code_only     — exit 0 = :ok, anything else = :error. Used by
    #   CI-fix style spawns where success is "the underlying command worked."
    # - :output_file_exists — exit 0 AND expected_output present + non-empty
    #   = :ok. Used by reviewer/triage spawns where a structured artifact
    #   is the success criterion.
    def handle_exit(result)
      if result[:timed_out]
        # Only the :state_file_marker mode writes :error to task.state_file
        # on timeout. The other modes leave the orchestrator-owned marker
        # in place (e.g., REVIEW_WORKING phase=reviewers stays so the
        # 5-review runner can decide whether to retry, escalate, or
        # convert to REVIEW_ERROR).
        if effective_status_mode == :state_file_marker
          Hive::Markers.set(@task.state_file, :error,
                            reason: "timeout",
                            timeout_sec: @timeout_sec)
        end
        result[:status] = :timeout
        return
      end

      case effective_status_mode
      when :state_file_marker
        handle_exit_state_file_marker(result)
      when :exit_code_only
        handle_exit_exit_code_only(result)
      when :output_file_exists
        handle_exit_output_file_exists(result)
      end
    end

    private

    def handle_exit_state_file_marker(result)
      if result[:exit_code].nil? || result[:exit_code].zero?
        # exit_code 0 = success; trust the marker the agent wrote.
        # exit_code nil = capture failed but child returned without timeout —
        # if no marker was written, that's a corrupted state, not silent OK.
        marker = Hive::Markers.current(@task.state_file)
        if marker.name == :none && result[:exit_code].nil?
          Hive::Markers.set(@task.state_file, :error, reason: "no_marker_no_exit_code")
          result[:status] = :error
        else
          result[:status] = marker.name
        end
      else
        Hive::Markers.set(@task.state_file, :error,
                          reason: "exit_code",
                          exit_code: result[:exit_code])
        result[:status] = :error
      end
    end

    # The :exit_code_only and :output_file_exists modes deliberately do
    # NOT write to task.state_file. The orchestrator owns the marker for
    # these flows (5-review's runner aggregates per-reviewer results and
    # writes a single REVIEW_* marker at the end of the phase). Writing
    # :error here would clobber the in-progress REVIEW_WORKING marker.
    # Caller reads result[:status] (:ok | :error) and result[:error_message]
    # to decide what to do.

    def handle_exit_exit_code_only(result)
      if result[:exit_code] == 0
        result[:status] = :ok
      else
        result[:status] = :error
        result[:error_message] = "exit_code=#{result[:exit_code]}"
      end
    end

    def handle_exit_output_file_exists(result)
      if result[:exit_code] != 0
        result[:status] = :error
        result[:error_message] = "exit_code=#{result[:exit_code]}"
        return
      end

      path = @expected_output
      if path.nil? || path.to_s.empty?
        result[:status] = :error
        result[:error_message] = "profile #{@profile.name} uses :output_file_exists but no expected_output was provided"
        return
      end

      unless File.exist?(path) && File.size(path) > 0
        result[:status] = :error
        result[:error_message] = "expected output file missing or empty: #{path}"
        return
      end

      result[:status] = :ok
    end

    def log_path
      ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      File.join(@task.log_dir, "#{@log_label}-#{ts}.log")
    end

    def ensure_log_dir
      FileUtils.mkdir_p(@task.log_dir)
    end
  end
end
