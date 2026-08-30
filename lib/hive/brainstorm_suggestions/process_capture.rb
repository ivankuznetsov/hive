# frozen_string_literal: true

module Hive
  module BrainstormSuggestions
    # Shared bounded subprocess lifecycle for repository observations. The
    # caller owns semantic error mapping; this helper owns concurrent draining,
    # deadlines, and unconditional process-group cleanup.
    module ProcessCapture
      Result = Data.define(:output, :status)
      class Timeout < StandardError; end
      class TooLarge < StandardError; end
      class SpawnFailed < StandardError; end

      module_function

      def call(argv, environment: {}, deadline:, max_bytes:, poll_interval: 0.02)
        reader, writer = IO.pipe
        pid = Process.spawn(
          environment, *argv, pgroup: true, in: File::NULL, out: writer, err: writer
        )
        writer.close
        output = +"".b
        reading = Thread.new do
          while (chunk = reader.read(65_536))
            output << chunk
            break if output.bytesize > max_bytes
          end
        end
        status = wait(pid, deadline: deadline, poll_interval: poll_interval)
        reading.join
        raise TooLarge if output.bytesize > max_bytes

        Result.new(output: output, status: status)
      rescue Timeout, TooLarge
        terminate(pid)
        raise
      rescue SystemCallError, IOError => error
        terminate(pid)
        raise SpawnFailed, error.message
      ensure
        writer&.close unless writer&.closed?
        reader&.close unless reader&.closed?
        reading&.kill if reading&.alive?
      end

      def wait(pid, deadline:, poll_interval:)
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          return waited.last if waited
          raise Timeout if monotonic_now >= deadline

          IO.select(nil, nil, nil, poll_interval)
        end
      end
      private_class_method :wait

      def terminate(pid)
        return unless pid

        Process.kill("TERM", -pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
      private_class_method :monotonic_now
    end
  end
end
