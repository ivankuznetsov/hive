module Hive
  module Daemon
    module QuiescenceFinalizer
      private
      def finalize(state, capability)
        writer_timeout = remaining(@budget.escalation_cutoff)
        return nonpaused("writer_drain_timeout", lifecycle: state) unless writer_timeout.positive?

        result = nil
        @database.with_exclusive_writer(role: :controller, timeout_sec: writer_timeout) do |authority|
          interrupted = finalize_stopped_processes_and_attempts(
            generation: state.generation, authority: authority
          )
          remaining_entries = final_remaining
          unless remaining_entries.empty?
            result = nonpaused(
              "work_remaining", lifecycle: @lifecycle.current, capability: capability,
              remaining: remaining_entries
            )
            next
          end
          if expired?(@budget.deadline)
            result = nonpaused("deadline_exhausted", lifecycle: @lifecycle.current)
            next
          end

          current = @lifecycle.current
          candidate = @lifecycle.mark_paused!(
            generation: current.generation, expected_revision: current.revision,
            interrupted_attempt_ids: interrupted, authority: authority, now: @clock.call,
            timeout_sec: remaining(@budget.deadline)
          )
          checkpoint = checkpoint_candidate(candidate, authority: authority)
          if checkpoint.is_a?(QuiescenceResult)
            result = checkpoint
            next
          end
          identity = installation_id
          @database.disconnect
          @successful_disconnect = true
          begin
            proof = @proof_store.publish!(
              lifecycle: candidate, installation_id: identity, checkpoint: checkpoint,
              interrupted_attempt_ids: interrupted, inventory: proof_inventory,
              published_at: @clock.call
            )
            if expired?(@budget.deadline)
              @proof_store.remove!
              @successful_disconnect = false
              @database.open!(timeout_sec: remaining(@budget.deadline))
              restored = @lifecycle.return_to_quiescing!(
                generation: candidate.generation, expected_revision: candidate.revision,
                authority: authority, now: @clock.call,
                timeout_sec: remaining(@budget.deadline)
              )
              result = nonpaused(
                "deadline_exhausted", lifecycle: restored, checkpoint: checkpoint
              )
            else
              result = paused_result(candidate, proof, checkpoint: checkpoint)
            end
          rescue StandardError => error
            @successful_disconnect = false
            @database.open!(timeout_sec: remaining(@budget.deadline))
            begin
              @proof_store.remove!
            rescue StandardError
              nil
            end
            restored = @lifecycle.return_to_quiescing!(
              generation: candidate.generation, expected_revision: candidate.revision,
              authority: authority, now: @clock.call,
              timeout_sec: remaining(@budget.deadline)
            )
            result = nonpaused(
              "proof_publication_failed", lifecycle: restored,
              checkpoint: checkpoint,
              details: { "error" => "#{error.class}: #{error.message}" }
            )
          end
        end
        result
      rescue Hive::ConcurrentRunError => error
        nonpaused(
          "writer_drain_timeout", lifecycle: state,
          remaining: [ { "role" => "writer", "unknown_reason" => "writer_fence_busy" } ],
          details: { "error" => error.message }
        )
      end

      def checkpoint_candidate(candidate, authority:)
        timeout = remaining(@budget.deadline)
        if timeout <= 0
          restored = rollback_candidate(candidate, authority)
          return nonpaused("deadline_exhausted", lifecycle: restored)
        end
        checkpoint = @database.checkpoint!(timeout_sec: timeout)
        unless checkpoint.fetch(:complete) && checkpoint.fetch(:busy).zero? &&
               checkpoint.fetch(:checkpointed_frames) >= checkpoint.fetch(:log_frames)
          restored = rollback_candidate(candidate, authority)
          return nonpaused(
            "checkpoint_busy", lifecycle: restored, checkpoint: checkpoint
          )
        end
        if expired?(@budget.deadline)
          restored = rollback_candidate(candidate, authority)
          return nonpaused(
            "deadline_exhausted", lifecycle: restored, checkpoint: checkpoint
          )
        end
        checkpoint
      rescue StandardError => error
        restored = rollback_candidate(candidate, authority)
        nonpaused(
          "checkpoint_error", lifecycle: restored,
          details: { "error" => "#{error.class}: #{error.message}" }
        )
      end

      def rollback_candidate(candidate, authority)
        @lifecycle.return_to_quiescing!(
          generation: candidate.generation, expected_revision: candidate.revision,
          authority: authority, now: @clock.call,
          timeout_sec: remaining(@budget.deadline)
        )
      end

      def finalize_stopped_processes_and_attempts(generation:, authority:)
        inventory_rows.each do |row|
          status = @process_identity.status(identity_hash(row))
          next unless %i[missing mismatched].include?(status)
          @registry.mark_stopped_by_process!(
            row.fetch(:process_id), authority: authority, reason: "quiesced",
            timeout_sec: remaining(@budget.deadline)
          )
        end

        interrupted = durable_interrupted_attempts(generation)
        store = attempt_store_if_needed
        return interrupted unless store
        reconciler = @reconciler || Hive::Attempts::Reconciler.new(
          store: store, process_identity: @process_identity
        )
        store.active_attempts.select { |record| record.state == "running" }.each do |record|
          outcome = reconciler.finalize_interruption(
            record, pause_generation: generation, now: @clock.call, authority: authority,
            timeout_sec: remaining(@budget.deadline)
          )
          interrupted << outcome.attempt.attempt_id if outcome.classification == :interrupted
        end
        interrupted.uniq.sort
      end
    end
  end
end
