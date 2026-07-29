require "hive/refactor_patrol/transition_evidence"

module Hive
  module RefactorPatrol
    # Job-level action transitions that are not owned by one action claim:
    # initialize a plan, reconcile a linked action, and block action progress.
    class ActionPlanTransitions
      def initialize(context:)
        @context = context
        @store = context.store
      end

      def initialize_actions(aggregate, specifications:, terminal_proofs:,
                             now:)
        job_id = aggregate.fetch("job_id")
        return @store.initialize_actions!(
          job_id,
          specifications: specifications,
          terminal_proofs: terminal_proofs,
          now: now
        ) unless @context.gateway

        planned = @store.plan_actions(
          job_id, specifications: specifications
        )
        action_ids = planned.map do |item|
          item.fetch("canonical_action_id")
        end.sort
        payload = {
          "action_ids" => action_ids,
          "terminal_proofs" => terminal_proofs
        }
        generation = @context.capture.owner_epoch
        @store.assert_recorded_transitions_terminal!(aggregate)
        @context.gateway.perform!(
          sink: "action",
          target: "#{job_id}:initialize",
          idempotency_key: [
            job_id,
            "initialize-actions",
            @context.digest(payload)
          ].join(":"),
          claim_generation: generation,
          scope: { "job_id" => job_id },
          claim_validator: ->(**) { true },
          reconcile: lambda do |intent|
            observed = @store.read_job(job_id)
            recorded = recorded_transition(
              observed, intent.intent_id
            )
            if recorded
              TransitionEvidence.matched_result(recorded)
            else
              observed_ids = observed.fetch("actions").map do |item|
                item.fetch("canonical_action_id")
              end.sort
              observed_ids.empty? ? @context.absent :
                @context.ambiguous
            end
          end,
          replay: ->(_result) { @store.read_job(job_id) },
          reject: job_rejection(
            job_id,
            operation: "initialize-actions",
            generation: generation,
            now: now
          )
        ) do |intent|
          @store.initialize_actions!(
            job_id,
            specifications: specifications,
            terminal_proofs: terminal_proofs,
            now: now,
            transition: transition(
              intent, operation: "initialize-actions"
            ),
            transition_generation: generation
          )
        end
      end

      def reconcile_linked(aggregate, action, now:)
        job_id = aggregate.fetch("job_id")
        action_id = action.fetch("canonical_action_id")
        return @store.reconcile_linked_action!(
          job_id, action_id, now: now
        ) unless @context.gateway

        generation = @context.capture.owner_epoch
        @store.assert_recorded_transitions_terminal!(aggregate)
        @context.gateway.perform!(
          sink: "action",
          target: "#{job_id}:#{action_id}:reconcile-link",
          idempotency_key: [
            job_id, action_id, "reconcile-linked-action"
          ].join(":"),
          claim_generation: generation,
          scope: @context.action_scope(job_id, action_id),
          claim_validator: ->(**) { true },
          reconcile: lambda do |intent|
            observed_aggregate = @store.read_job(job_id)
            observed = @context.find_action(
              observed_aggregate, action_id
            )
            recorded = recorded_transition(
              observed_aggregate, intent.intent_id
            )
            if recorded
              TransitionEvidence.matched_result(recorded)
            elsif observed&.fetch("terminal") == true
              @context.ambiguous
            else
              @context.absent
            end
          end,
          replay: ->(_result) { @store.read_job(job_id) },
          reject: job_rejection(
            job_id,
            operation: "reconcile-linked-action",
            generation: generation,
            now: now
          )
        ) do |intent|
          @store.reconcile_linked_action!(
            job_id,
            action_id,
            now: now,
            transition: transition(
              intent, operation: "reconcile-linked-action"
            ),
            transition_generation: generation
          )
        end
      end

      def materialize_terminal_proof(aggregate, action_id, proof:, now:)
        job_id = aggregate.fetch("job_id")
        return @store.materialize_terminal_proof!(
          job_id, action_id, proof: proof, now: now
        ) unless @context.gateway

        generation = @context.capture.owner_epoch
        @store.assert_recorded_transitions_terminal!(aggregate)
        @context.gateway.perform!(
          sink: "action",
          target: "#{job_id}:#{action_id}:materialize-terminal-proof",
          idempotency_key: [
            job_id,
            action_id,
            "materialize-terminal-proof",
            @context.digest(proof)
          ].join(":"),
          claim_generation: generation,
          scope: @context.action_scope(job_id, action_id),
          claim_validator: ->(**) { true },
          reconcile: lambda do |intent|
            observed = @store.read_job(job_id)
            action = @context.find_action(
              observed, action_id
            )
            recorded = recorded_transition(
              observed, intent.intent_id
            )
            recorded ?
              TransitionEvidence.matched_result(recorded) : @context.absent
          end,
          replay: ->(_result) { @store.read_job(job_id) },
          reject: job_rejection(
            job_id,
            operation: "materialize-terminal-proof",
            generation: generation,
            now: now
          )
        ) do |intent|
          @store.materialize_terminal_proof!(
            job_id,
            action_id,
            proof: proof,
            now: now,
            transition: transition(
              intent, operation: "materialize-terminal-proof"
            ),
            transition_generation: generation
          )
        end
      end

      def block(aggregate, reason:, evidence:, backoff_sec:, now:)
        job_id = aggregate.fetch("job_id")
        gateway = @context.gateway(diagnostic_transition: true)
        return @store.block_actions!(
          job_id,
          reason: reason,
          evidence: evidence,
          now: now,
          backoff_sec: backoff_sec
        ) unless gateway

        episode = @store.next_diagnostic_episode(
          aggregate, "action_block"
        )
        @store.assert_recorded_transitions_terminal!(aggregate)
        gateway.perform!(
          sink: "action",
          target: "#{job_id}:block",
          idempotency_key: [
            job_id,
            "action-block",
            reason,
            @context.digest(evidence),
            episode
          ].join(":"),
          claim_generation: episode,
          scope: { "job_id" => job_id },
          claim_validator: ->(**) { true },
          reconcile: lambda do |intent|
            observed = @store.read_job(job_id)
            matched = observed.fetch("attempts").reverse_each.find do |attempt|
              attempt["kind"] == "action_block" &&
                attempt["generation"] == episode &&
                Array(attempt["transitions"]).any? do |record|
                  record["intent_id"] == intent.intent_id
                end
            end
            matched ? TransitionEvidence.matched_result(
              matched.fetch("transitions").find do |record|
                record["intent_id"] == intent.intent_id
              end
            ) : @context.absent
          end,
          replay: ->(_result) { @store.read_job(job_id) },
          reject: job_rejection(
            job_id,
            operation: "action-block",
            generation: episode,
            now: now
          )
        ) do |intent|
          @store.block_actions!(
            job_id,
            reason: reason,
            evidence: evidence,
            now: now,
            backoff_sec: backoff_sec,
            episode: episode,
            transition: transition(
              intent, operation: "action-block"
            )
          )
        end
      end

      private

      def transition(intent, operation:, error_code: nil)
        TransitionEvidence.record(
          intent,
          operation: operation,
          error_code: error_code
        )
      end

      def recorded_transition(aggregate, intent_id)
        attempt_transition = aggregate.fetch("attempts").filter_map do |attempt|
          Array(attempt["transitions"]).find do |record|
            record["intent_id"] == intent_id
          end
        end.first
        return attempt_transition if attempt_transition

        aggregate.fetch("actions").filter_map do |action|
          action_transition(action, intent_id)
        end.first
      end

      def action_transition(action, intent_id)
        Array(action && action["transitions"]).find do |record|
          record["intent_id"] == intent_id
        end
      end

      def job_rejection(job_id, operation:, generation:, now:)
        lambda do |intent, _error, error_code|
          @store.record_job_transition_rejection!(
            job_id,
            operation: "#{operation}-rejection",
            generation: generation,
            transition: transition(
              intent,
              operation: operation,
              error_code: error_code
            ),
            now: now
          )
        end
      end
    end
  end
end
