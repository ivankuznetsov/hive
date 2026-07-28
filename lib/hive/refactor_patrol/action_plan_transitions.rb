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
        @context.gateway.perform!(
          sink: "action",
          target: "#{job_id}:initialize",
          idempotency_key: [
            job_id,
            "initialize-actions",
            @context.digest(payload)
          ].join(":"),
          claim_generation: @context.capture.owner_epoch,
          scope: { "job_id" => job_id },
          claim_validator: ->(**) { true },
          reconcile: lambda do |_intent|
            observed = @store.read_job(job_id)
            observed_ids = observed.fetch("actions").map do |item|
              item.fetch("canonical_action_id")
            end.sort
            initialize_reconciliation(observed_ids, action_ids)
          end,
          replay: ->(_result) { @store.read_job(job_id) }
        ) do
          @store.initialize_actions!(
            job_id,
            specifications: specifications,
            terminal_proofs: terminal_proofs,
            now: now
          )
        end
      end

      def reconcile_linked(aggregate, action, now:)
        job_id = aggregate.fetch("job_id")
        action_id = action.fetch("canonical_action_id")
        return @store.reconcile_linked_action!(
          job_id, action_id, now: now
        ) unless @context.gateway

        @context.gateway.perform!(
          sink: "action",
          target: "#{job_id}:#{action_id}:reconcile-link",
          idempotency_key: [
            job_id, action_id, "reconcile-linked-action"
          ].join(":"),
          claim_generation: @context.capture.owner_epoch,
          scope: @context.action_scope(job_id, action_id),
          claim_validator: ->(**) { true },
          reconcile: lambda do |_intent|
            observed = @context.find_action(
              @store.read_job(job_id), action_id
            )
            if observed&.fetch("terminal") == true
              {
                "status" => "matched",
                "outcome" => {
                  "outcome" => observed.fetch("outcome")
                }
              }
            else
              @context.absent
            end
          end,
          replay: ->(_result) { @store.read_job(job_id) }
        ) do
          @store.reconcile_linked_action!(
            job_id, action_id, now: now
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

        gateway.perform!(
          sink: "action",
          target: "#{job_id}:block",
          idempotency_key: [
            job_id,
            "action-block",
            reason,
            @context.digest(evidence)
          ].join(":"),
          claim_generation: @context.capture.owner_epoch,
          scope: { "job_id" => job_id },
          claim_validator: ->(**) { true },
          reconcile: lambda do |_intent|
            observed = @store.read_job(job_id)
            matched = observed.fetch("attempts").reverse_each.find do |attempt|
              attempt["kind"] == "action_block" &&
                attempt["reason"] == reason.to_s &&
                attempt.fetch("evidence", {}) == evidence
            end
            if matched
              {
                "status" => "matched",
                "outcome" => { "state" => observed.fetch("state") }
              }
            else
              @context.absent
            end
          end,
          replay: ->(_result) { @store.read_job(job_id) }
        ) do
          @store.block_actions!(
            job_id,
            reason: reason,
            evidence: evidence,
            now: now,
            backoff_sec: backoff_sec
          )
        end
      end

      private

      def initialize_reconciliation(observed_ids, expected_ids)
        if observed_ids == expected_ids
          {
            "status" => "matched",
            "outcome" => { "action_count" => observed_ids.size }
          }
        elsif observed_ids.empty?
          @context.absent
        else
          @context.ambiguous
        end
      end
    end
  end
end
