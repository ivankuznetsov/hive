require "fileutils"
require "json"
require "time"

module Hive
  class Agent
    DEFAULT_BIN = "claude".freeze

    attr_reader :task, :prompt, :add_dirs, :cwd, :max_budget_usd, :timeout_sec

    def initialize(task:, prompt:, max_budget_usd:, timeout_sec:, add_dirs: [], cwd: nil, log_label: nil)
      @task = task
      @prompt = prompt
      @add_dirs = Array(add_dirs)
      @cwd = cwd || task.folder
      @max_budget_usd = max_budget_usd
      @timeout_sec = timeout_sec
      @log_label = log_label || task.stage_name
    end

    def self.bin
      ENV["HIVE_CLAUDE_BIN"] || DEFAULT_BIN
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
          sleep [remaining, 0.2].min
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

    def build_cmd
      cmd = [Agent.bin, "-p"]
      cmd << "--dangerously-skip-permissions"
      @add_dirs.each do |d|
        cmd << "--add-dir" << d
      end
      cmd << "--max-budget-usd" << @max_budget_usd.to_s
      cmd << "--output-format" << "stream-json"
      cmd << "--include-partial-messages"
      cmd << "--verbose"
      cmd << "--no-session-persistence"
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

    def handle_exit(result)
      if result[:timed_out]
        Hive::Markers.set(@task.state_file, :error,
                          reason: "timeout",
                          timeout_sec: @timeout_sec)
        result[:status] = :timeout
      elsif result[:exit_code].nil? || result[:exit_code].zero?
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

    def log_path
      ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      File.join(@task.log_dir, "#{@log_label}-#{ts}.log")
    end

    def ensure_log_dir
      FileUtils.mkdir_p(@task.log_dir)
    end

    def self.check_version!
      cached = (@verified_versions ||= {})[bin]
      return cached if cached

      out, _err, status = Open3.capture3(bin, "--version")
      raise AgentError, "claude binary not runnable: #{bin}" unless status.success?

      version = out[/\d+\.\d+\.\d+/]
      raise AgentError, "could not parse claude --version output: #{out.inspect}" unless version

      compare = version_tuple(version) <=> version_tuple(Hive::MIN_CLAUDE_VERSION)
      raise AgentError, "claude #{version} below minimum #{Hive::MIN_CLAUDE_VERSION}" if compare.nil? || compare.negative?

      @verified_versions[bin] = version
    end

    def self.version_tuple(version_string)
      version_string.split(".").map(&:to_i)
    end
  end
end

require "open3"
