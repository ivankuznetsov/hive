require "hive/refactor_patrol/transition_evidence"

module Hive
  module RefactorPatrol
    # Diagnostic discovery/action block transitions outside a live claim.
    class DiscoveryBlockTransitions
      def initialize(context:)
        @context = context
      end

      def block(entry:, store:, aggregate:, phase:, reason:, evidence:, now:,
                backoff_sec:)
        phase = phase.to_sym
        direct = lambda do |transition: nil, episode: nil|
          block_direct(
            store,
            aggregate,
            phase: phase,
            reason: reason,
            evidence: evidence,
            now: now,
            backoff_sec: backoff_sec,
            episode: episode,
            transition: transition
          )
        end
        return direct.call unless @context.gateway_supported?(store)

        capture = store.occurrence_capture(aggregate.fetch("job_id"))
        capture ||= @context.reserve_occurrence(
          entry, store, aggregate, now
        )
        job_id = aggregate.fetch("job_id")
        kind = phase == :action ? "action_block" : "discovery_block"
        episode = store.next_diagnostic_episode(aggregate, kind)
        store.assert_recorded_transitions_terminal!(aggregate)
        @context.gateway(
          entry,
          store,
          capture,
          now,
          diagnostic_transition: true
        ).perform!(
          sink: phase == :action ? "action" : "discovery",
          target: "#{job_id}:block",
          idempotency_key: [
            job_id,
            phase,
            "block",
            reason,
            @context.digest(evidence),
            episode
          ].join(":"),
          claim_generation: episode,
          scope: { "job_id" => job_id },
          claim_validator: ->(**) { true },
          reconcile: lambda do |intent|
            observed = store.read_job(job_id)
            block_reconciliation(
              observed,
              kind: kind,
              episode: episode,
              intent_id: intent.intent_id
            )
          end,
          replay: ->(_result) { store.read_job(job_id) },
          reject: lambda do |intent, _error, error_code|
            store.record_job_transition_rejection!(
              job_id,
              operation: "#{kind.tr('_', '-')}-rejection",
              generation: episode,
              transition: transition(
                intent,
                operation: kind.tr("_", "-"),
                error_code: error_code
              ),
              now: now
            )
          end
        ) do |intent|
          direct.call(
            episode: episode,
            transition: transition(
              intent,
              operation: kind.tr("_", "-")
            )
          )
        end
      end

      private

      def block_direct(store, aggregate, phase:, reason:, evidence:, now:,
                       backoff_sec:, episode:, transition:)
        arguments = {
          reason: reason,
          evidence: evidence,
          now: now,
          backoff_sec: backoff_sec,
          episode: episode,
          transition: transition
        }
        if phase == :action
          store.block_actions!(aggregate.fetch("job_id"), **arguments)
        else
          store.block_discovery!(aggregate.fetch("job_id"), **arguments)
        end
      end

      def block_reconciliation(aggregate, kind:, episode:, intent_id:)
        found = aggregate.fetch("attempts").find do |attempt|
          attempt["generation"] == episode &&
            Array(attempt["transitions"]).any? do |record|
              record["intent_id"] == intent_id
            end
        end
        found ? @context.matched(aggregate) : @context.absent
      end

      def transition(intent, operation:, error_code: nil)
        TransitionEvidence.record(
          intent,
          operation: operation,
          error_code: error_code
        )
      end
    end
  end
end
