require "hive/refactor_patrol/publication_attempt"

module Hive
  module RefactorPatrol
    # Claim-scoped action transitions: claim, settle, and write-once receipt
    # updates. Every live mutation is fenced and exactly reconcilable.
    class ActionClaimTransitions
      def initialize(context:, owner:, owner_pid:,
                     owner_process_start_time:, lease_sec:, claim_resolver:)
        @context = context
        @store = context.store
        @owner = owner
        @owner_pid = owner_pid
        @owner_process_start_time = owner_process_start_time
        @lease_sec = lease_sec
        @claim_resolver = claim_resolver
      end

      def claim(aggregate, action, authority:, now:)
        generation = Array(action["claims"]).filter_map do |claim|
          claim["generation"]
        end.max.to_i + 1
        job_id = aggregate.fetch("job_id")
        action_id = action.fetch("canonical_action_id")
        return claim_direct(
          job_id, action_id, authority: authority, now: now
        ) unless @context.gateway

        @context.gateway.perform!(
          sink: "action",
          target: "#{job_id}:#{action_id}:claim",
          idempotency_key: [
            job_id, action_id, "claim", generation
          ].join(":"),
          claim_generation: generation,
          scope: @context.action_scope(job_id, action_id),
          claim_validator: ->(**) { true },
          reconcile: lambda do |_intent|
            observed = @context.action_claim(
              job_id, action_id, generation
            )
            claim_reconciliation(observed, generation)
          end,
          replay: lambda do |_result|
            observed = @context.action_claim(
              job_id, action_id, generation
            )
            next nil unless owned_active_claim?(observed)

            {
              job_id: job_id,
              canonical_action_id: action_id,
              owner: @owner,
              generation: generation,
              continuation_only:
                observed["authority"] == "continuation_only"
            }
          end
        ) do
          claim_direct(
            job_id, action_id, authority: authority, now: now
          )
        end
      end

      def settle(token, outcome:, receipts:, terminal:, backoff_sec:, now:)
        operation = terminal ? "finish" : "release"
        return settle_direct(
          token,
          outcome: outcome,
          receipts: receipts,
          terminal: terminal,
          backoff_sec: backoff_sec,
          now: now
        ) unless @context.gateway

        job_id = token.fetch(:job_id)
        action_id = token.fetch(:canonical_action_id)
        generation = token.fetch(:generation)
        @context.gateway.perform!(
          sink: "action",
          target: "#{job_id}:#{action_id}:#{operation}",
          idempotency_key: [
            job_id,
            action_id,
            operation,
            generation,
            outcome,
            @context.digest(receipts)
          ].join(":"),
          claim_generation: generation,
          scope: @context.action_scope(job_id, action_id),
          claim_validator: @context.claim_validator(token, now),
          reconcile: lambda do |_intent|
            aggregate = @store.read_job(job_id)
            action = @context.find_action(aggregate, action_id)
            claim = @context.find_claim(action, generation)
            settle_reconciliation(
              aggregate,
              action,
              claim,
              outcome: outcome,
              receipts: receipts,
              terminal: terminal
            )
          end,
          replay: ->(_result) { @store.read_job(job_id) }
        ) do
          settle_direct(
            token,
            outcome: outcome,
            receipts: receipts,
            terminal: terminal,
            backoff_sec: backoff_sec,
            now: now
          )
        end
      end

      def record_patch_publication(token, patch:, now:)
        attempt_id = PublicationAttempt.id_for(
          publication_base_sha: patch.fetch("publication_base_sha"),
          commit_sha: patch.fetch("commit_sha")
        )
        claimed_transition(
          token,
          operation: "record-patch-publication",
          payload: patch,
          now: now,
          matcher: lambda do |action|
            !PublicationAttempt.state_for(
              action.fetch("receipts"), attempt_id
            ).nil?
          end
        ) do
          @store.record_patch_publication_attempt!(
            token, receipt: patch, now: now
          )
        end
      end

      def record_creation_intent(token, phase, payload, now:)
        claimed_transition(
          token,
          operation: "record-#{phase}",
          payload: payload,
          now: now,
          matcher: lambda do |action|
            action.dig("receipts", "creation_intent", "payload") ==
              payload
          end
        ) do
          @store.record_creation_intent!(
            token, intent: payload, now: now
          )
        end
      end

      def record_action_receipt(token, phase, payload, now:)
        claimed_transition(
          token,
          operation: "record-#{phase}",
          payload: payload,
          now: now,
          matcher: lambda do |action|
            action.dig("receipts", phase) == payload
          end
        ) do
          @store.record_action_receipt!(
            token, key: phase, value: payload, now: now
          )
        end
      end

      def claimed_transition(token, operation:, payload:, matcher:, now:,
                             &transition)
        return transition.call unless @context.gateway

        job_id = token.fetch(:job_id)
        action_id = token.fetch(:canonical_action_id)
        generation = token.fetch(:generation)
        @context.gateway.perform!(
          sink: "action",
          target: "#{job_id}:#{action_id}:#{operation}",
          idempotency_key: [
            job_id,
            action_id,
            operation,
            generation,
            @context.digest(payload)
          ].join(":"),
          claim_generation: generation,
          scope: @context.action_scope(job_id, action_id),
          claim_validator: @context.claim_validator(token, now),
          reconcile: lambda do |_intent|
            aggregate = @store.read_job(job_id)
            action = @context.find_action(aggregate, action_id)
            claim = @context.find_claim(action, generation)
            if action && matcher.call(action)
              {
                "status" => "matched",
                "outcome" => { "state" => aggregate.fetch("state") }
              }
            elsif @context.active_claim?(claim)
              @context.absent
            else
              @context.ambiguous
            end
          end,
          replay: ->(_result) { @store.read_job(job_id) },
          &transition
        )
      end

      private

      def claim_direct(job_id, action_id, authority:, now:)
        @store.claim_action!(
          job_id,
          action_id,
          owner: @owner,
          now: now,
          lease_sec: @lease_sec,
          claim_resolver: @claim_resolver,
          owner_pid: @owner_pid,
          owner_process_start_time: @owner_process_start_time,
          authority: authority
        )
      end

      def settle_direct(token, outcome:, receipts:, terminal:, backoff_sec:,
                        now:)
        if terminal
          @store.finish_action!(
            token,
            outcome: outcome,
            receipts: receipts,
            now: now
          )
        else
          @store.release_action!(
            token,
            outcome: outcome,
            receipts: receipts,
            now: now,
            backoff_sec: backoff_sec
          )
        end
      end

      def claim_reconciliation(observed, generation)
        if owned_active_claim?(observed)
          {
            "status" => "matched",
            "outcome" => { "generation" => generation }
          }
        elsif observed
          @context.ambiguous
        else
          @context.absent
        end
      end

      def settle_reconciliation(aggregate, action, claim, outcome:, receipts:,
                                terminal:)
        matched = if terminal
          action && action["terminal"] == true &&
            action["outcome"] == outcome.to_s &&
            receipts.all? do |key, value|
              action.fetch("receipts")[key.to_s] == value
            end
        else
          claim && claim["state"] == "released" &&
            claim["outcome"] == outcome.to_s
        end
        if matched
          {
            "status" => "matched",
            "outcome" => { "state" => aggregate.fetch("state") }
          }
        elsif @context.active_claim?(claim)
          @context.absent
        else
          @context.ambiguous
        end
      end

      def owned_active_claim?(claim)
        claim && claim["owner"] == @owner &&
          @context.active_claim?(claim)
      end
    end
  end
end
