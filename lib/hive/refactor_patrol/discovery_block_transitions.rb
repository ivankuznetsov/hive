require "hive/refactor_patrol/transition_evidence"

module Hive
  module RefactorPatrol
    # Diagnostic discovery block transitions outside a live claim. The action
    # branch remains only to validate historical v4 records; no runtime caller
    # schedules it.
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

      def retire(entry:, store:, aggregate:, merge_sha:, trunk_sha:, now:,
                 claim_resolver: nil)
        job_id = aggregate.fetch("job_id")
        non_applied_status = nil
        status = store.obsolete_source_retirement_status(
          job_id, claim_resolver: claim_resolver
        )
        return status unless status == :retireable

        direct = lambda do |transition: nil, episode: nil|
          result = store.retire_obsolete_source!(
            job_id,
            merge_sha: merge_sha,
            trunk_sha: trunk_sha,
            now: now,
            claim_resolver: claim_resolver,
            episode: episode,
            transition: transition
          )
          if result != :retired
            non_applied_status = result
            next nil
          end
          result
        end
        unless @context.gateway_supported?(store)
          applied = direct.call
          return non_applied_status if non_applied_status

          return retirement_result(store, job_id) if applied == :retired
          return applied
        end

        capture = store.occurrence_capture(job_id)
        capture ||= @context.reserve_occurrence(entry, store, aggregate, now)
        episode = store.next_diagnostic_episode(
          aggregate, JobStore::SOURCE_RETIREMENT_ATTEMPT_KIND
        )
        store.assert_recorded_transitions_terminal!(aggregate)
        @context.gateway(
          entry, store, capture, now,
          diagnostic_transition: true
        ).perform!(
          sink: "job",
          target: "#{job_id}:source-retirement",
          idempotency_key: [
            job_id, "source-retirement", merge_sha, trunk_sha, episode
          ].join(":"),
          claim_generation: episode,
          scope: { "job_id" => job_id },
          claim_validator: ->(**) { true },
          reconcile: lambda do |intent|
            block_reconciliation(
              store.read_job(job_id),
              kind: JobStore::SOURCE_RETIREMENT_ATTEMPT_KIND,
              episode: episode,
              intent_id: intent.intent_id
            )
          end,
          replay: ->(_result) { store.read_job(job_id) }
        ) do |intent|
          direct.call(
            episode: episode,
            transition: transition(
              intent, operation: "source-retirement"
            )
          )
        end
        return non_applied_status if non_applied_status

        retirement_result(store, job_id)
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

      def block_reconciliation(aggregate, kind:, episode:, intent_id:,
                               require_complete: false)
        return @context.absent if require_complete && !aggregate.fetch("complete")

        found = aggregate.fetch("attempts").find do |attempt|
          attempt["kind"] == kind && attempt["generation"] == episode &&
            Array(attempt["transitions"]).any? do |record|
              record["intent_id"] == intent_id
            end
        end
        found ? @context.matched(aggregate) : @context.absent
      end

      def retirement_result(store, job_id)
        status = store.obsolete_source_retirement_status(job_id)
        status == :already_terminal ? :retired : status
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
