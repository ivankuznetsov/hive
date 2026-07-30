require "hive/refactor_patrol/publication_attempt"
require "hive/refactor_patrol/transition_evidence"

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
          reconcile: lambda do |intent|
            aggregate = @store.read_job(job_id)
            observed_action = @context.find_action(
              aggregate, action_id
            )
            observed = @context.find_claim(
              observed_action, generation
            )
            claim_reconciliation(
              observed_action, observed, intent.intent_id
            )
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
        ) do |intent|
          claim_direct(
            job_id,
            action_id,
            authority: authority,
            now: now,
            transition: transition(
              intent,
              operation: "claim"
            )
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
          reconcile: lambda do |intent|
            aggregate = @store.read_job(job_id)
            action = @context.find_action(aggregate, action_id)
            claim = @context.find_claim(action, generation)
            transition_reconciliation(
              action, claim, intent.intent_id
            )
          end,
          replay: ->(_result) { @store.read_job(job_id) },
          reject: rejection(
            token,
            operation: operation,
            now: now
          )
        ) do |intent|
          settle_direct(
            token,
            outcome: outcome,
            receipts: receipts,
            terminal: terminal,
            backoff_sec: backoff_sec,
            now: now,
            transition: transition(
              intent,
              operation: operation
            )
          )
        end
      end

      def record_patch_publication(token, patch:, now:)
        claimed_transition(
          token,
          operation: "record-patch-publication",
          payload: patch,
          now: now
        ) do |effect_transition|
          @store.record_patch_publication_attempt!(
            token,
            receipt: patch,
            now: now,
            transition: effect_transition
          )
        end
      end

      def record_patch_receipt(token, receipt:, now:)
        claimed_transition(
          token,
          operation: "record-patch-receipt",
          payload: receipt,
          now: now
        ) do |effect_transition|
          @store.record_patch_receipt!(
            token,
            receipt: receipt,
            now: now,
            transition: effect_transition
          )
        end
      end

      def record_publication_phase(token, attempt_id:, phase:, payload:,
                                   now:)
        evidence = {
          "attempt_id" => attempt_id,
          "phase" => phase,
          "payload" => payload
        }
        claimed_transition(
          token,
          operation: "record-publication-#{phase}",
          payload: evidence,
          now: now
        ) do |effect_transition|
          @store.record_publication_attempt_phase!(
            token,
            attempt_id: attempt_id,
            phase: phase,
            payload: payload,
            now: now,
            transition: effect_transition
          )
        end
      end

      def supersede_publication(token, attempt_id:, observed_head_sha:, now:)
        evidence = {
          "attempt_id" => attempt_id,
          "observed_head_sha" => observed_head_sha
        }
        claimed_transition(
          token,
          operation: "supersede-publication",
          payload: evidence,
          now: now
        ) do |effect_transition|
          @store.supersede_publication_attempt!(
            token,
            attempt_id: attempt_id,
            observed_head_sha: observed_head_sha,
            now: now,
            transition: effect_transition
          )
        end
      end

      def record_fix_receipt(token, receipt:, now:)
        claimed_transition(
          token,
          operation: "record-fix-receipt",
          payload: receipt,
          now: now
        ) do |effect_transition|
          @store.record_fix_receipt!(
            token,
            receipt: receipt,
            now: now,
            transition: effect_transition
          )
        end
      end

      def record_creation_intent(token, phase, payload, now:)
        claimed_transition(
          token,
          operation: "record-#{phase}",
          payload: payload,
          now: now
        ) do |effect_transition|
          @store.record_creation_intent!(
            token,
            intent: payload,
            now: now,
            transition: effect_transition
          )
        end
      end

      def record_action_receipt(token, phase, payload, now:)
        claimed_transition(
          token,
          operation: "record-#{phase}",
          payload: payload,
          now: now
        ) do |effect_transition|
          @store.record_action_receipt!(
            token,
            key: phase,
            value: payload,
            now: now,
            transition: effect_transition
          )
        end
      end

      def claimed_transition(token, operation:, payload:, now:,
                             &transition)
        return transition.call(nil) unless @context.gateway

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
          reconcile: lambda do |intent|
            aggregate = @store.read_job(job_id)
            action = @context.find_action(aggregate, action_id)
            claim = @context.find_claim(action, generation)
            transition_reconciliation(
              action, claim, intent.intent_id
            )
          end,
          replay: ->(_result) { @store.read_job(job_id) },
          reject: rejection(
            token,
            operation: operation,
            now: now
          )
        ) do |intent|
          transition.call(
            transition(
              intent,
              operation: operation
            )
          )
        end
      end

      private

      def claim_direct(job_id, action_id, authority:, now:,
                       transition: nil)
        @store.claim_action!(
          job_id,
          action_id,
          owner: @owner,
          now: now,
          lease_sec: @lease_sec,
          claim_resolver: @claim_resolver,
          owner_pid: @owner_pid,
          owner_process_start_time: @owner_process_start_time,
          authority: authority,
          transition: transition
        )
      end

      def settle_direct(token, outcome:, receipts:, terminal:, backoff_sec:,
                        now:, transition: nil)
        if terminal
          @store.finish_action!(
            token,
            outcome: outcome,
            receipts: receipts,
            now: now,
            transition: transition
          )
        else
          @store.release_action!(
            token,
            outcome: outcome,
            receipts: receipts,
            now: now,
            backoff_sec: backoff_sec,
            transition: transition
          )
        end
      end

      def claim_reconciliation(action, observed, intent_id)
        entry = transition_entry(action, intent_id)
        if owned_active_claim?(observed) && entry
          TransitionEvidence.matched_result(entry)
        elsif observed
          @context.ambiguous
        else
          @context.absent
        end
      end

      def transition_reconciliation(action, claim, intent_id)
        entry = transition_entry(action, intent_id)
        if entry
          TransitionEvidence.matched_result(entry)
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

      def transition(intent, operation:, error_code: nil)
        TransitionEvidence.record(
          intent,
          operation: operation,
          error_code: error_code
        )
      end

      def rejection(token, operation:, now:)
        lambda do |intent, _error, error_code|
          @store.record_action_transition_rejection!(
            token,
            transition: transition(
              intent,
              operation: operation,
              error_code: error_code
            ),
            now: now
          )
        end
      end

      def transition_entry(action, intent_id)
        Array(action && action["transitions"]).find do |entry|
          entry["intent_id"] == intent_id
        end
      end
    end
  end
end
