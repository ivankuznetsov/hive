module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ContainmentRoot
      POLL_INTERVAL = 0.01

      def initialize(protocol:, budget:, output_limit:, exact_secrets:,
                     secret_patterns:, worker_factory:, owner_factory: nil,
                     warden_factory: nil)
        @protocol = protocol
        @budget = budget
        @output_limit = output_limit
        @exact_secrets = exact_secrets
        @secret_patterns = secret_patterns
        @worker_factory = worker_factory
        @owner_factory = owner_factory
        @warden_factory =
          warden_factory || lambda { |pid|
            ContainmentWarden.new(root_pid: pid, budget: @budget)
          }
      end

      def run(parent_writer:, cancel_reader:, request:)
        interrupted = false
        Signal.trap("TERM") { interrupted = true }
        Signal.trap("INT") { interrupted = true }
        provisional = nil
        owner_status = nil
        failure = nil
        warden = @warden_factory.call(Process.pid)
        warden.enable_child_subreaper!
        owner_reader, owner_writer = IO.pipe
        owner_pid = Process.fork do
          owner_reader.close
          parent_writer.close unless parent_writer.closed?
          cancel_reader.close unless cancel_reader.closed?
          build_owner.run(owner_writer, request)
        end
        owner_writer.close
        provisional, owner_status = monitor_owner(
          owner_reader: owner_reader,
          cancel_reader: cancel_reader,
          parent_writer: parent_writer,
          owner_pid: owner_pid,
          interrupted: -> { interrupted }
        )
      rescue Failure => e
        failure = e
      rescue StandardError => e
        failure = Failure.new(
          phase: "process",
          reason: "containment_failed",
          detail: "#{e.class}: #{e.message}"
        )
      ensure
        Signal.trap("TERM", "IGNORE")
        Signal.trap("INT", "IGNORE")
        remaining, cleanup_failure = close_child_domain(warden)
        failure ||= cleanup_failure
        outcome =
          if failure
            failure_outcome(failure)
          else
            finalize_outcome(provisional, owner_status, warden, remaining)
          end
        safe_write_outcome(parent_writer, outcome)
        close_quietly(owner_reader)
        close_quietly(owner_writer)
        close_quietly(cancel_reader)
        close_quietly(parent_writer)
        exit! 0
      end

      private

      def build_owner
        arguments = {
          protocol: @protocol,
          budget: @budget,
          output_limit: @output_limit,
          exact_secrets: @exact_secrets,
          secret_patterns: @secret_patterns,
          worker_factory: @worker_factory
        }
        return @owner_factory.call(**arguments) if @owner_factory

        ContainmentOwner.new(**arguments)
      end

      def monitor_owner(owner_reader:, cancel_reader:, parent_writer:, owner_pid:,
                        interrupted:)
        stream = @protocol.stream_reader
        ready = false
        provisional = nil
        owner_status = nil
        deadline = monotonic_now + @budget.owner_seconds
        loop do
          fail_containment!("process containment caller canceled") if interrupted.call
          remaining = deadline - monotonic_now
          fail_containment!("process containment owner exceeded result deadline") unless
            remaining.positive?

          readers = [ cancel_reader ]
          readers.unshift(owner_reader) unless stream.eof?
          readable = IO.select(
            readers,
            nil,
            nil,
            [ POLL_INTERVAL, remaining ].min
          )
          fail_containment!("process containment caller canceled") if
            interrupted.call || readable&.first&.include?(cancel_reader)
          if readable&.first&.include?(owner_reader)
            @protocol.read_available(stream, owner_reader).each do |frame|
              if !ready
                worker_pid = @protocol.decode_owner_ready_frame(frame)
                @protocol.write_ready(
                  parent_writer,
                  owner_pid: owner_pid,
                  worker_pid: worker_pid
                )
                ready = true
              elsif provisional.nil?
                provisional = @protocol.decode_owner_outcome_frame(frame)
              else
                fail_containment!("owner result stream contains trailing data")
              end
            end
          end

          owner_status ||= observe_owner(owner_pid)
          if owner_status&.stopped?
            fail_containment!("process containment owner stopped unexpectedly")
          end
          if owner_status && stream.eof?
            @protocol.finish_stream!(stream)
            fail_containment!("process containment owner exited before ready") unless ready
            fail_containment!("process containment owner exited without a result") unless
              provisional
            return [ provisional, owner_status ]
          end
        end
      end

      def observe_owner(pid)
        waited, status = Process.wait2(
          pid,
          Process::WNOHANG | Process::WUNTRACED
        )
        waited ? status : nil
      rescue Errno::ECHILD
        fail_containment!("process containment owner was not waitable")
      end

      def close_child_domain(warden)
        return [ [], nil ] unless warden

        remaining = warden.drain_child_domain
        return [ remaining, nil ] if remaining.empty?

        [
          remaining,
          Failure.new(
            phase: "process",
            reason: "containment_failed",
            detail: "containment root retained #{remaining.length} descendant(s)"
          )
        ]
      rescue StandardError => e
        [
          [],
          Failure.new(
            phase: "process",
            reason: "containment_failed",
            detail: "containment root cleanup failed: #{e.class}: #{e.message}"
          )
        ]
      end

      def finalize_outcome(provisional, owner_status, warden, remaining)
        unless owner_status&.success?
          return @protocol.failure_outcome(
            reason: "containment_failed",
            detail: "process containment owner exited unsuccessfully"
          )
        end
        return provisional unless provisional.success?

        payload = provisional.result
        worker = payload.delete("worker_teardown")
        reaped = worker.fetch("target_reaped") &&
                 worker.fetch("descendants") == "none" &&
                 remaining.empty?
        status =
          if reaped && worker.fetch("readers") == "complete" &&
             worker.fetch("writer") == "complete"
            "passed"
          else
            "failed"
          end
        payload.fetch("record")["teardown"] = {
          "status" => status,
          "term_sent" => worker.fetch("term_sent") || warden.term_sent,
          "kill_sent" => worker.fetch("kill_sent") || warden.kill_sent,
          "reaped" => reaped,
          "readers" => worker.fetch("readers"),
          "writer" => worker.fetch("writer"),
          "descendants" => remaining.empty? ? "none" : "remaining",
          "containment" => WORKFLOW_CREATOR_PROCESS_CONTAINMENT,
          "teardown_authority" => WORKFLOW_CREATOR_TEARDOWN_AUTHORITY,
          "root_loss_guarantee" => WORKFLOW_CREATOR_ROOT_LOSS_GUARANTEE
        }
        @protocol.success_outcome(payload)
      end

      def safe_write_outcome(writer, outcome)
        return if writer.nil? || writer.closed?

        @protocol.write_parent_outcome(writer, outcome)
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

      def close_quietly(io)
        io&.close unless io&.closed?
      rescue IOError, SystemCallError
        nil
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
