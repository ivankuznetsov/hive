module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ContainmentSession
      attr_reader :pid

      def self.start(protocol:, budget:, output_limit:, exact_secrets:,
                     secret_patterns:, request:, worker_factory: nil)
        reader, writer = IO.pipe
        pid = Process.fork do
          reader.close
          ContainmentOwner.new(
            protocol: protocol,
            budget: budget,
            output_limit: output_limit,
            exact_secrets: exact_secrets,
            secret_patterns: secret_patterns,
            worker_factory: worker_factory
          ).run(writer, request)
        end
        writer.close
        new(pid: pid, reader: reader, protocol: protocol, budget: budget)
      rescue StandardError
        close_quietly(reader)
        close_quietly(writer)
        raise
      end

      def self.close_quietly(io)
        io&.close unless io&.closed?
      rescue IOError, SystemCallError
        nil
      end
      private_class_method :close_quietly

      def initialize(pid:, reader:, protocol:, budget:)
        @pid = pid
        @reader = reader
        @protocol = protocol
        @budget = budget
        @reaped = false
      end

      def result
        deadline = monotonic_now + @budget.parent_seconds
        worker_pid = @protocol.read_ready(@reader, deadline: deadline)
        yield worker_pid
        frame = @protocol.read_parent_frame(@reader, deadline: deadline)
        @protocol.expect_eof!(@reader, deadline: deadline)
        status = wait_for_owner(deadline)
        @reaped = true
        fail_containment!("process containment owner exited unsuccessfully") unless
          status.success?

        @protocol.decode_parent_frame(frame)
      end

      def shutdown
        return if @reaped

        signal_owner_shutdown
        deadline = monotonic_now + @budget.owner_shutdown_seconds
        loop do
          waited = Process.waitpid(@pid, Process::WNOHANG)
          if waited
            @reaped = true
            return
          end
          break if monotonic_now >= deadline

          sleep 0.01
        rescue Errno::ECHILD
          @reaped = true
          return
        end
        kill_owner
        Process.waitpid(@pid)
        @reaped = true
      rescue Errno::ECHILD
        @reaped = true
      end

      def close
        @reader.close unless @reader.closed?
      end

      private

      def signal_owner_shutdown
        Process.kill("CONT", @pid)
        Process.kill("TERM", @pid)
      rescue Errno::ESRCH
        nil
      end

      def kill_owner
        Process.kill("KILL", @pid)
      rescue Errno::ESRCH
        nil
      end

      def wait_for_owner(deadline)
        loop do
          waited, status = Process.wait2(@pid, Process::WNOHANG)
          return status if waited
          fail_containment!("process containment owner exceeded result deadline") if
            monotonic_now >= deadline
          sleep 0.01
        end
      rescue Errno::ECHILD
        fail_containment!("process containment owner was not waitable")
      end

      def fail_containment!(detail)
        raise Failure.new(
          phase: "process",
          reason: "containment_failed",
          detail: detail
        )
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
