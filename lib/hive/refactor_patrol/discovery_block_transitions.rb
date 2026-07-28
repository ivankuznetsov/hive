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
        direct = lambda do
          block_direct(
            store,
            aggregate,
            phase: phase,
            reason: reason,
            evidence: evidence,
            now: now,
            backoff_sec: backoff_sec
          )
        end
        return direct.call unless @context.gateway_supported?(store)

        capture = store.occurrence_capture(aggregate.fetch("job_id"))
        capture ||= @context.reserve_occurrence(
          entry, store, aggregate, now
        )
        job_id = aggregate.fetch("job_id")
        kind = phase == :action ? "action_block" : "discovery_block"
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
            @context.digest(evidence)
          ].join(":"),
          claim_generation: capture.owner_epoch,
          scope: { "job_id" => job_id },
          claim_validator: ->(**) { true },
          reconcile: lambda do |_intent|
            observed = store.read_job(job_id)
            block_reconciliation(
              observed,
              kind: kind,
              reason: reason,
              evidence: evidence
            )
          end,
          replay: ->(_result) { store.read_job(job_id) },
          &direct
        )
      end

      private

      def block_direct(store, aggregate, phase:, reason:, evidence:, now:,
                       backoff_sec:)
        operation = phase == :action ?
          :block_actions! : :block_discovery!
        store.public_send(
          operation,
          aggregate.fetch("job_id"),
          reason: reason,
          evidence: evidence,
          now: now,
          backoff_sec: backoff_sec
        )
      end

      def block_reconciliation(aggregate, kind:, reason:, evidence:)
        found = aggregate.fetch("attempts").reverse_each.find do |attempt|
          attempt["kind"] == kind &&
            attempt["reason"] == reason.to_s &&
            attempt.fetch("evidence", {}) == evidence
        end
        found ? @context.matched(aggregate) : @context.absent
      end
    end
  end
end
