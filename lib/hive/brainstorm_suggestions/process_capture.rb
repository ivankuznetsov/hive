# frozen_string_literal: true

module Hive
  module BrainstormSuggestions
    # Shared bounded subprocess lifecycle for repository observations. The
    # caller owns semantic error mapping; this helper owns concurrent draining,
    # deadlines, and unconditional process-group cleanup.
    module ProcessCapture
      TERM_GRACE_SECONDS = 0.5
      POLL_INTERVAL_SECONDS = 0.02
      Result = Data.define(:output, :status)
      class Timeout < StandardError; end
      class TooLarge < StandardError; end
      class SpawnFailed < StandardError; end

      module_function

      def call(argv, environment: {}, deadline:, max_bytes:, poll_interval: 0.02)
        cleanup_complete = false
        reader, writer = IO.pipe
        pid = Process.spawn(
          environment, *argv, pgroup: true, in: File::NULL, out: writer, err: writer
        )
        writer.close
        output = +"".b
        status = nil
        eof = false
        loop do
          eof = drain(reader, output, max_bytes) || eof
          status ||= wait_nonblock(pid)
          if status && eof
            terminate(pid) if process_group_alive?(pid)
            cleanup_complete = true
            return Result.new(output: output, status: status)
          end
          raise Timeout if monotonic_now >= deadline

          wait_for = [ poll_interval, deadline - monotonic_now ].min
          IO.select([ reader ], nil, nil, wait_for) if wait_for.positive? && !eof
          IO.select(nil, nil, nil, wait_for) if wait_for.positive? && eof
        end
      rescue Timeout, TooLarge
        raise
      rescue SystemCallError, IOError => error
        raise SpawnFailed, error.message
      ensure
        terminate(pid) if pid && !cleanup_complete
        writer&.close unless writer&.closed?
        reader&.close unless reader&.closed?
      end

      def drain(reader, output, max_bytes)
        loop do
          chunk = reader.read_nonblock(65_536, exception: false)
          case chunk
          when :wait_readable
            return false
          when nil
            return true
          else
            output << chunk
            raise TooLarge if output.bytesize > max_bytes
          end
        end
      end
      private_class_method :drain

      def wait_nonblock(pid)
        Process.waitpid2(pid, Process::WNOHANG)&.last
      rescue Errno::ECHILD
        nil
      end
      private_class_method :wait_nonblock

      def terminate(pid)
        return unless pid
        return unless process_group_alive?(pid) || process_alive?(pid)

        signal_group("TERM", pid)
        deadline = monotonic_now + TERM_GRACE_SECONDS
        loop do
          wait_nonblock(pid)
          return pid unless process_group_alive?(pid)
          break if monotonic_now >= deadline

          IO.select(nil, nil, nil, POLL_INTERVAL_SECONDS)
        end
        signal_group("KILL", pid)
        kill_deadline = monotonic_now + (POLL_INTERVAL_SECONDS * 5)
        loop do
          wait_nonblock(pid)
          break unless process_group_alive?(pid)
          break if monotonic_now >= kill_deadline

          IO.select(nil, nil, nil, POLL_INTERVAL_SECONDS)
        end
        pid
      end

      def process_group_alive?(pid)
        Process.kill(0, -pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end
      private_class_method :process_group_alive?

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end
      private_class_method :process_alive?

      def signal_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        nil
      end
      private_class_method :signal_group

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
      private_class_method :monotonic_now
    end
  end
end
