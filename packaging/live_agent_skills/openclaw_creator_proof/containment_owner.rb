module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ContainmentOwner
      def initialize(protocol:, budget:, output_limit:, exact_secrets:,
                     secret_patterns:, worker_factory:)
        @protocol = protocol
        @budget = budget
        @output_limit = output_limit
        @exact_secrets = exact_secrets
        @secret_patterns = secret_patterns
        @worker_factory = worker_factory
      end

      def run(writer, request)
        interrupted = false
        Signal.trap("TERM") { interrupted = true }
        Signal.trap("INT") { interrupted = true }
        warden = ContainmentWarden.new(root_pid: Process.pid, budget: @budget)
        worker_reader, worker_writer = IO.pipe
        worker = Process.fork do
          worker_reader.close
          writer.close unless writer.closed?
          write_worker_result(worker_writer, request)
        end
        worker_writer.close
        @protocol.write_owner_ready(writer, worker)
        deadline = monotonic_now + @budget.owner_seconds
        outcome, worker_status = await_worker_outcome(
          worker_reader,
          worker,
          warden,
          deadline: deadline,
          interrupted: -> { interrupted }
        )
        outcome = prepare_outcome(outcome, worker_status, warden)
        @protocol.write_owner_outcome(writer, outcome)
      rescue Failure => e
        safe_write_failure(writer, e)
      rescue StandardError => e
        safe_write_failure(
          writer,
          Failure.new(
            phase: "process",
            reason: "containment_failed",
            detail: "#{e.class}: #{e.message}"
          )
        )
      ensure
        Signal.trap("TERM", "IGNORE")
        Signal.trap("INT", "IGNORE")
        emergency_cleanup(worker, warden)
        worker_reader&.close unless worker_reader&.closed?
        worker_writer&.close unless worker_writer&.closed?
        writer.close unless writer.closed?
        exit! 0
      end

      private

      def await_worker_outcome(reader, worker, warden, deadline:, interrupted:)
        outcome = nil
        status = nil
        loop do
          if interrupted.call
            warden.terminate_worker(worker)
            status = warden.reap_specific(worker)
            return [
              @protocol.failure_outcome(
                reason: "containment_failed",
                detail: "process containment worker was interrupted"
              ),
              status
            ]
          end

          unless outcome
            ready = IO.select([ reader ], nil, nil, 0.01)
            if ready
              begin
                outcome = @protocol.read_worker_outcome(reader, deadline: deadline)
              rescue Failure => e
                outcome = failure_outcome(e)
              end
            end
          end
          status ||= warden.reap_specific(worker, nonblock: true)
          if status && outcome
            begin
              @protocol.expect_eof!(reader, deadline: deadline)
            rescue Failure => e
              outcome = failure_outcome(e)
            end
            return [ outcome, status ]
          end
          if status && !outcome
            return [
              @protocol.failure_outcome(
                reason: "containment_failed",
                detail: "process worker exited without a complete result"
              ),
              status
            ]
          end
          next if monotonic_now < deadline

          warden.terminate_worker(worker)
          status ||= warden.reap_specific(worker)
          return [
            @protocol.failure_outcome(
              reason: "containment_failed",
              detail: "process worker exceeded the monotonic result deadline"
            ),
            status
          ]
        end
      end

      def write_worker_result(writer, request)
        Signal.trap("TERM") { raise Interrupt }
        worker = build_worker
        outcome = @protocol.success_outcome(worker.call(**request))
      rescue Interrupt
        outcome = @protocol.failure_outcome(
          reason: "interrupted",
          detail: "process worker was interrupted"
        )
      rescue Failure => e
        outcome = failure_outcome(e)
      rescue StandardError => e
        outcome = @protocol.failure_outcome(
          reason: "containment_failed",
          detail: "#{e.class}: #{e.message}"
        )
      ensure
        Signal.trap("TERM", "IGNORE")
        begin
          @protocol.write_worker_outcome(
            writer,
            outcome || @protocol.failure_outcome(
              reason: "containment_failed",
              detail: "process worker exited without a result"
            )
          )
        rescue Failure, Errno::EPIPE, IOError
          nil
        end
        writer.close unless writer.closed?
        exit! 0
      end

      def build_worker
        arguments = {
          budget: @budget,
          output_limit: @output_limit,
          exact_secrets: @exact_secrets,
          secret_patterns: @secret_patterns
        }
        return @worker_factory.call(**arguments) if @worker_factory

        CaptureWorker.new(**arguments)
      end

      def prepare_outcome(outcome, worker_status, warden)
        warden.drain_remaining_descendants
        warden.reap_adopted_children
        remaining = warden.descendants
        unless remaining.empty?
          return @protocol.failure_outcome(
            reason: "containment_failed",
            detail: "process owner retained #{remaining.length} descendant(s)"
          )
        end
        if outcome.success? && !worker_status&.success?
          return @protocol.failure_outcome(
            reason: "containment_failed",
            detail: "process worker exited unsuccessfully"
          )
        end
        return outcome unless outcome.success?

        payload = outcome.result
        worker = payload.fetch("worker_teardown")
        worker["term_sent"] ||= warden.term_sent
        worker["kill_sent"] ||= warden.kill_sent
        @protocol.success_outcome(payload)
      end

      def emergency_cleanup(worker, warden)
        if worker && warden && warden.process_alive?(worker)
          warden.terminate_worker(worker)
        end
        warden&.drain_remaining_descendants
        warden&.reap_adopted_children
      rescue StandardError
        nil
      end

      def safe_write_failure(writer, failure)
        return if writer.nil? || writer.closed?

        @protocol.write_owner_outcome(writer, failure_outcome(failure))
      rescue Failure, Errno::EPIPE, IOError
        nil
      end

      def failure_outcome(failure)
        @protocol.failure_outcome(
          phase: failure.phase,
          reason: failure.reason,
          detail: failure.message
        )
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
