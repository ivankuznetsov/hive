require "fileutils"
require "json"
require "open3"
require "time"
require "hive/agent_profiles"

module Hive
  class Agent
    # Backward compat: the `bin` reader is preserved at the class level so
    # external callers that still ask for `Hive::Agent.bin` (without holding
    # a profile) get the claude binary path. Production call sites all pass
    # a profile via Stages::Base.spawn_agent. Tests historically stub
    # ENV["HIVE_CLAUDE_BIN"] — the claude profile honors that env var, so
    # the test pattern keeps working unchanged after the refactor.
    DEFAULT_BIN = "claude".freeze

    attr_reader :task, :prompt, :add_dirs, :cwd, :max_budget_usd, :timeout_sec,
                :profile, :expected_output

    def initialize(task:, prompt:, max_budget_usd:, timeout_sec:,
                   add_dirs: [], cwd: nil, log_label: nil,
                   profile: nil, expected_output: nil)
      @task = task
      @prompt = prompt
      @add_dirs = Array(add_dirs)
      @cwd = cwd || task.folder
      @max_budget_usd = max_budget_usd
      @timeout_sec = timeout_sec
      @log_label = log_label || task.stage_name
      @profile = profile || Hive::AgentProfiles.lookup(:claude)
      @expected_output = expected_output
    end

    # Backward-compat class methods. Resolve to the claude profile so legacy
    # call sites (Hive::Agent.bin, Hive::Agent.check_version!) keep working.
    def self.bin
      Hive::AgentProfiles.lookup(:claude).bin
    end

    def self.check_version!
      Hive::AgentProfiles.lookup(:claude).check_version!
    end

    def run!
      ensure_log_dir
      Hive::Markers.set(@task.state_file, :agent_working,
                        pid: Process.pid,
                        started: Time.now.utc.iso8601)
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
      cmd.concat(@profile.output_format_flags) if @profile.output_format_flags
      cmd.concat(@profile.extra_flags) if @profile.extra_flags
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
        Hive::Markers.set(@task.state_file, :error,
                          reason: "timeout",
                          timeout_sec: @timeout_sec)
        result[:status] = :timeout
        return
      end

      case @profile.status_detection_mode
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

    def handle_exit_exit_code_only(result)
      if result[:exit_code] == 0
        result[:status] = :ok
      else
        Hive::Markers.set(@task.state_file, :error,
                          reason: "exit_code",
                          exit_code: result[:exit_code])
        result[:status] = :error
      end
    end

    def handle_exit_output_file_exists(result)
      if result[:exit_code] != 0
        Hive::Markers.set(@task.state_file, :error,
                          reason: "exit_code",
                          exit_code: result[:exit_code])
        result[:status] = :error
        return
      end

      path = @expected_output
      if path.nil? || path.to_s.empty?
        Hive::Markers.set(@task.state_file, :error,
                          reason: "missing_expected_output_path")
        result[:status] = :error
        result[:error_message] = "profile #{@profile.name} uses :output_file_exists but no expected_output was provided"
        return
      end

      unless File.exist?(path) && File.size(path) > 0
        Hive::Markers.set(@task.state_file, :error,
                          reason: "missing_or_empty_output",
                          path: path)
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
