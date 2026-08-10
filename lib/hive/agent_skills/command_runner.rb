require "open3"
require "timeout"

module Hive
  module AgentSkills
    CommandResult = Data.define(:stdout, :stderr, :exit_status, :error, :timed_out) do
      def success?
        !timed_out && error.nil? && exit_status == 0
      end
    end

    class CommandRunner
      POLL_INTERVAL_SEC = 0.01
      TERM_GRACE_SEC = 0.5
      REAP_GRACE_SEC = 0.2

      def call(argv, env: {}, timeout: 10, chdir: nil)
        timeout = Float(timeout)
        raise ArgumentError, "command timeout must be positive" unless timeout.finite? && timeout.positive?

        options = { pgroup: true }
        options[:chdir] = chdir if chdir
        stdin, stdout, stderr, waiter = Open3.popen3(env, *argv, **options)
        stdin.close
        readers = [ capture_reader(stdout), capture_reader(stderr) ]
        deadline = monotonic_now + timeout
        status = nil

        loop do
          unless waiter.alive?
            status = waiter.value
            break if readers.none?(&:alive?)
          end

          remaining = deadline - monotonic_now
          raise Timeout::Error, "command timed out after #{timeout}s" if remaining <= 0

          sleep [ POLL_INTERVAL_SEC, remaining ].min
        end

        CommandResult.new(
          stdout: readers[0].value,
          stderr: readers[1].value,
          exit_status: status.exitstatus,
          error: nil,
          timed_out: false
        )
      rescue Timeout::Error => e
        terminate_process_group(waiter) if waiter
        stop_readers(readers, stdout, stderr)
        CommandResult.new(stdout: "", stderr: "", exit_status: nil, error: e.message, timed_out: true)
      rescue SystemCallError => e
        CommandResult.new(stdout: "", stderr: "", exit_status: nil, error: "#{e.class}: #{e.message}", timed_out: false)
      ensure
        [ stdin, stdout, stderr ].each do |io|
          io.close if io && !io.closed?
        rescue IOError
          nil
        end
      end

      private

      def capture_reader(io)
        Thread.new do
          Thread.current.report_on_exception = false
          io.read
        rescue IOError
          ""
        end
      end

      def terminate_process_group(waiter)
        pid = waiter.pid
        signal_process_group("TERM", pid)
        deadline = monotonic_now + TERM_GRACE_SEC
        while process_group_alive?(pid) && monotonic_now < deadline
          sleep POLL_INTERVAL_SEC
        end
        signal_process_group("KILL", pid) if process_group_alive?(pid)
        waiter.join(REAP_GRACE_SEC)
      end

      def stop_readers(readers, *streams)
        Array(readers).each { |reader| reader.join(REAP_GRACE_SEC) }
        streams.each do |stream|
          stream.close if stream && !stream.closed?
        rescue IOError
          nil
        end
        Array(readers).each { |reader| reader.kill if reader.alive? }
      end

      def signal_process_group(signal, pid)
        Process.kill(signal, -Integer(pid))
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def process_group_alive?(pid)
        Process.kill(0, -Integer(pid))
        true
      rescue Errno::ESRCH, Errno::ECHILD
        false
      rescue Errno::EPERM
        true
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
