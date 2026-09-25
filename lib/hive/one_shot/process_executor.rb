require "json"
require "shellwords"
require "hive/config"
require "hive/errors"
require "hive/runtime_control_plane/process_guard"

module Hive
  module OneShot
    class ProcessExecutor
      Execution = Data.define(:exit_code, :envelope)
      DEFAULT_TIMEOUT_SEC = 3600
      DEFAULT_KILL_GRACE_SEC = 30
      POLL_SEC = 0.01
      POST_KILL_REAP_SEC = 1

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
        new(
          timeout_sec: timeouts.max || DEFAULT_TIMEOUT_SEC,
          kill_grace_sec: daemon_cfg.fetch(
            "child_kill_grace_sec", DEFAULT_KILL_GRACE_SEC
          )
        )
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
        stdout = reader_value(stdout_reader, deadline, pid)
        stderr = reader_value(stderr_reader, deadline, pid)
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
        signal_group("TERM", pid)
        deadline = monotonic_now + @kill_grace_sec
        status = wait_for_exit(pid, deadline)
        wait_for_group_exit(pid, deadline) if process_group_alive?(pid)
        return status unless process_group_alive?(pid)

        signal_group("KILL", pid)
        kill_deadline = monotonic_now + POST_KILL_REAP_SEC
        status ||= wait_for_exit(pid, kill_deadline)
        wait_for_group_exit(pid, kill_deadline)
        status
      end

      def reader_value(reader, deadline, pid)
        return reader.value if reader.join([ deadline - monotonic_now, 0 ].max)

        terminate(pid)
        raise Hive::InternalError,
              "one-shot child timed out while draining output after #{@timeout_sec} seconds"
      end

      def wait_for_exit(pid, deadline)
        loop do
          waited = Process.wait2(pid, Process::WNOHANG)
          return waited.last if waited
          return nil if monotonic_now >= deadline

          @sleeper.call([ POLL_SEC, deadline - monotonic_now ].min)
        end
      rescue Errno::ECHILD
        nil
      end

      def signal_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        nil
      end

      def process_group_alive?(pid)
        Process.kill(0, -pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def wait_for_group_exit(pid, deadline)
        while process_group_alive?(pid) && monotonic_now < deadline
          @sleeper.call([ POLL_SEC, deadline - monotonic_now ].min)
        end
      end

      def monotonic_now = @monotonic_clock.call
    end
  end
end
