module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ContainmentSession
      attr_reader :pid

      def self.start(protocol:, budget:, output_limit:, exact_secrets:,
                     secret_patterns:, request:, worker_factory: nil,
                     root_factory: nil)
        reader, writer = IO.pipe
        cancel_reader, cancel_writer = IO.pipe
        pid = Process.fork do
          reader.close
          cancel_writer.close
          root_arguments = {
            protocol: protocol,
            budget: budget,
            output_limit: output_limit,
            exact_secrets: exact_secrets,
            secret_patterns: secret_patterns,
            worker_factory: worker_factory
          }
          root =
            if root_factory
              root_factory.call(**root_arguments)
            else
              ContainmentRoot.new(**root_arguments)
            end
          root.run(
            parent_writer: writer,
            cancel_reader: cancel_reader,
            request: request
          )
        end
        writer.close
        cancel_reader.close
        new(
          pid: pid,
          reader: reader,
          cancel_writer: cancel_writer,
          protocol: protocol,
          budget: budget
        )
      rescue StandardError
        close_quietly(reader)
        close_quietly(writer)
        close_quietly(cancel_reader)
        close_quietly(cancel_writer)
        raise
      end

      def self.close_quietly(io)
        io&.close unless io&.closed?
      rescue IOError, SystemCallError
        nil
      end
      private_class_method :close_quietly

      def initialize(pid:, reader:, cancel_writer:, protocol:, budget:)
        @pid = pid
        @reader = reader
        @cancel_writer = cancel_writer
        @protocol = protocol
        @budget = budget
        @reaped = false
      end

      def result
        deadline = monotonic_now + @budget.parent_seconds
        first = @protocol.read_parent_frame(@reader, deadline: deadline)
        frame =
          if first["frame"] == "ready"
            yield @protocol.decode_ready_frame(first)
            @protocol.read_parent_frame(@reader, deadline: deadline)
          else
            first
          end
        @protocol.expect_eof!(@reader, deadline: deadline)
        status = wait_for_root(deadline)
        @reaped = true
        fail_containment!("process containment root exited unsuccessfully") unless
          status.success?

        @protocol.decode_parent_frame(frame)
      end

      def shutdown
        return if @reaped

        signal_root_continue
        request_cancel
        deadline = monotonic_now + @budget.owner_shutdown_seconds
        status = wait_for_root(deadline)
        @reaped = true
        return if status.success?

        fail_authority!("process containment root exited unsuccessfully")
      end

      def close
        self.class.send(:close_quietly, @cancel_writer)
        self.class.send(:close_quietly, @reader)
      end

      private

      def signal_root_continue
        Process.kill("CONT", @pid)
      rescue Errno::ESRCH
        nil
      end

      def request_cancel
        return if @cancel_writer.closed?

        @cancel_writer.write_nonblock("C", exception: false)
        @cancel_writer.close
      rescue Errno::EPIPE, IOError
        nil
      end

      def wait_for_root(deadline)
        loop do
          waited, status = Process.wait2(@pid, Process::WNOHANG)
          return status if waited
          fail_authority!("process containment root exceeded shutdown deadline") if
            monotonic_now >= deadline

          sleep 0.01
        end
      rescue Errno::ECHILD
        fail_authority!("process containment root was not waitable")
      end

      def fail_authority!(detail)
        raise Failure.new(
          phase: "process",
          reason: "containment_authority_lost",
          detail: detail
        )
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
