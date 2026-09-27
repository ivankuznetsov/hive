require "json"
require "shellwords"
require "hive/config"
require "hive/daemon/child_supervisor"
require "hive/errors"
require "hive/runtime_control_plane/process_guard"

module Hive
  module OneShot
    class ProcessExecutor
      Execution = Data.define(:exit_code, :envelope)
      DEFAULT_TIMEOUT_SEC = 3600
      DEFAULT_KILL_GRACE_SEC = 30
      PARENT_HEADROOM_SEC = 60
      OUTPUT_DRAIN_TIMEOUT_SEC = 5

      def self.for_entry(entry, config_loader: ->(path) { Hive::Config.load(path) },
                         daemon_config_loader: -> { Hive::Config.load_global_daemon })
        cfg = config_loader.call(entry.fetch("path"))
        timeouts = [
          cfg.dig("timeout_sec", "patrol"),
          cfg.dig("refactor_patrol", "max_review_seconds_per_run")
        ].filter_map do |value|
          seconds = Float(value)
          seconds if seconds.positive?
        rescue ArgumentError, TypeError
          nil
        end
        daemon_cfg = daemon_config_loader.call
        kill_grace_sec = daemon_cfg.fetch(
          "child_kill_grace_sec", DEFAULT_KILL_GRACE_SEC
        )
        worker_timeout = timeouts.max
        parent_timeout = if worker_timeout
          worker_timeout + [ PARENT_HEADROOM_SEC, Float(kill_grace_sec) ].max
        else
          DEFAULT_TIMEOUT_SEC
        end
        new(timeout_sec: parent_timeout, kill_grace_sec: kill_grace_sec)
      end

      def initialize(timeout_sec: DEFAULT_TIMEOUT_SEC,
                     kill_grace_sec: DEFAULT_KILL_GRACE_SEC,
                     monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     sleeper: ->(seconds) { sleep(seconds) })
        @timeout_sec = Float(timeout_sec)
        @kill_grace_sec = Float(kill_grace_sec)
        raise ArgumentError, "one-shot child timeout must be positive" unless @timeout_sec.positive?
        raise ArgumentError, "one-shot child kill grace must be non-negative" if @kill_grace_sec.negative?

        @monotonic_clock = monotonic_clock
        @sleeper = sleeper
      rescue ArgumentError, TypeError
        raise ArgumentError, "one-shot child timeout and kill grace must be valid numbers"
      end

      def call(command, on_spawn: nil)
        pid = nil
        settled = false
        terminating = false
        stdout_reader = nil
        stderr_reader = nil
        out_read, out_write = IO.pipe
        err_read, err_write = IO.pipe
        Hive::RuntimeControlPlane::ProcessGuard.before_fork!
        argv = Shellwords.split(command)
        hive_bin = ENV.fetch("HIVE_BIN", "hive")
        argv[0] = hive_bin if argv.first == "hive" || argv.first&.end_with?("/hive") ||
          argv.first == File.basename(hive_bin)
        pid = Process.spawn(
          *argv, in: File::NULL, out: out_write,
          err: err_write, pgroup: true
        )
        Hive::RuntimeControlPlane::ProcessGuard.after_fork_parent!
        out_write.close
        err_write.close
        on_spawn&.call(pid)
        stdout_reader = Thread.new { out_read.read }
        stderr_reader = Thread.new { err_read.read }
        deadline = monotonic_now + @timeout_sec
        status = wait_for_exit(pid, deadline)
        unless status
          terminating = true
          terminate(pid)
          raise Hive::InternalError,
                "one-shot child timed out after #{@timeout_sec} seconds"
        end
        drain_deadline = output_drain_deadline
        stdout = reader_value(stdout_reader, drain_deadline, pid)
        stderr = reader_value(stderr_reader, drain_deadline, pid)
        settled = true
        $stderr.write(stderr) unless stderr.empty?
        envelope = JSON.parse(stdout) unless stdout.strip.empty?
        Execution.new(exit_code: status.exitstatus || 1, envelope: envelope)
      rescue JSON::ParserError => error
        raise Hive::InternalError, "one-shot child returned invalid JSON: #{error.message}"
      rescue Exception
        terminate(pid) if pid && !settled && !terminating
        raise
      ensure
        Hive::RuntimeControlPlane::ProcessGuard.after_fork_parent!
        [ out_read, out_write, err_read, err_write ].compact.each do |io|
          io.close unless io.closed?
        end
        [ stdout_reader, stderr_reader ].compact.each do |reader|
          reader.kill if reader.alive?
          reader.join
        end
      end

      private

      def terminate(pid)
        Hive::Daemon::ChildSupervisor.terminate_pid(
          pid: pid, pgid: pid, grace_sec: @kill_grace_sec,
          monotonic_clock: @monotonic_clock, sleeper: @sleeper
        )
      end

      def reader_value(reader, deadline, pid)
        return reader.value if reader.join([ deadline - monotonic_now, 0 ].max)

        terminate(pid)
        raise Hive::InternalError,
              "one-shot child timed out while draining output after #{@timeout_sec} seconds"
      end

      def wait_for_exit(pid, deadline)
        Hive::Daemon::ChildSupervisor.wait_for_pid(
          pid: pid, deadline: deadline,
          monotonic_clock: @monotonic_clock, sleeper: @sleeper
        )
      end

      def output_drain_deadline = monotonic_now + OUTPUT_DRAIN_TIMEOUT_SEC

      def monotonic_now = @monotonic_clock.call
    end
  end
end
