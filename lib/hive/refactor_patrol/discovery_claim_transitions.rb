require "json"
require "time"

module Hive
  module RefactorPatrol
    # Discovery claim-scoped protocol: acquire, checkpoint, and release with
    # exact reconciliation against JobStore attempts.
    class DiscoveryClaimTransitions
      def initialize(context:, owner_pid:, owner_process_start_time:,
                     lease_sec:, claim_resolver:, reservation_error:,
                     claim_operation: "discovery-claim",
                     operation_prefix: "discovery-")
        @context = context
        @owner_pid = owner_pid
        @owner_process_start_time = owner_process_start_time
        @lease_sec = lease_sec
        @claim_resolver = claim_resolver
        @reservation_error = reservation_error
        @claim_operation = claim_operation
        @operation_prefix = operation_prefix
      end

      def claim(entry:, store:, capture:, aggregate:, analysis_sha:, now:)
        return claim_direct(
          store,
          aggregate.fetch("job_id"),
          analysis_sha: analysis_sha,
          now: now,
          resolver: @claim_resolver
        ) unless @context.gateway_supported?(store)

        resolver = claim_resolver(aggregate, now)
        return unless resolver

        generation = next_generation(aggregate)
        job_id = aggregate.fetch("job_id")
        @context.gateway(entry, store, capture, now).perform!(
          sink: "discovery",
          target: "#{job_id}:claim",
          idempotency_key: [
            job_id, @claim_operation, generation, analysis_sha
          ].join(":"),
          claim_generation: generation,
          scope: { "job_id" => job_id },
          claim_validator: ->(**) { true },
          reconcile: lambda do |_intent|
            observed = store.read_job(job_id)
            attempt = @context.discovery_attempt(
              observed, generation
            )
            claim_reconciliation(attempt, generation)
          end,
          replay: lambda do |_result|
            observed = store.read_job(job_id)
            attempt = @context.discovery_attempt(
              observed, generation
            )
            next nil unless
              @context.owned_active_attempt?(attempt)

            {
              job_id: job_id,
              owner: @context.owner,
              generation: generation
            }
          end
        ) do
          claimed = claim_direct(
            store,
            job_id,
            analysis_sha: analysis_sha,
            now: now,
            resolver: resolver
          )
          unless claimed
            raise @reservation_error.new("claim_unavailable")
          end

          claimed
        end
      end

      def release(entry:, store:, token:, reason:, now:, backoff_sec:)
        return release_direct(
          store,
          token,
          reason: reason,
          now: now,
          backoff_sec: backoff_sec
        ) unless @context.gateway_supported?(store)

        job_id = token.fetch(:job_id)
        generation = token.fetch(:generation)
        capture = store.occurrence_capture(job_id)
        return release_direct(
          store,
          token,
          reason: reason,
          now: now,
          backoff_sec: backoff_sec
        ) unless capture

        @context.gateway(entry, store, capture, now).perform!(
          sink: "discovery",
          target: "#{job_id}:release",
          idempotency_key: [
            job_id, operation_name("release"), generation, reason
          ].join(":"),
          claim_generation: generation,
          scope: { "job_id" => job_id },
          claim_validator:
            @context.claim_validator(store, token, now),
          reconcile: lambda do |_intent|
            observed = store.read_job(job_id)
            attempt = @context.discovery_attempt(
              observed, generation
            )
            release_reconciliation(observed, attempt, reason)
          end,
          replay: ->(_result) { store.read_job(job_id) }
        ) do
          release_direct(
            store,
            token,
            reason: reason,
            now: now,
            backoff_sec: backoff_sec
          )
        end
      end

      def checkpoint(entry:, store:, token:, envelope:, now:, backoff_sec:)
        return checkpoint_direct(
          store,
          token,
          envelope: envelope,
          now: now,
          backoff_sec: backoff_sec
        ) unless @context.gateway_supported?(store)

        job_id = token.fetch(:job_id)
        generation = token.fetch(:generation)
        capture = store.occurrence_capture(job_id)
        return checkpoint_direct(
          store,
          token,
          envelope: envelope,
          now: now,
          backoff_sec: backoff_sec
        ) unless capture

        @context.gateway(entry, store, capture, now).perform!(
          sink: "discovery",
          target: "#{job_id}:checkpoint",
          idempotency_key: [
            job_id,
            operation_name("checkpoint"),
            generation,
            @context.digest(envelope)
          ].join(":"),
          claim_generation: generation,
          scope: { "job_id" => job_id },
          claim_validator:
            @context.claim_validator(store, token, now),
          reconcile: lambda do |_intent|
            observed = store.read_job(job_id)
            attempt = @context.discovery_attempt(
              observed, generation
            )
            checkpoint_reconciliation(
              observed, attempt, envelope
            )
          end,
          replay: ->(_result) { store.read_job(job_id) }
        ) do
          checkpoint_direct(
            store,
            token,
            envelope: envelope,
            now: now,
            backoff_sec: backoff_sec
          )
        end
      end

      def checkpoint_progress(entry:, store:, token:, envelope:, now:,
                              lease_sec:)
        return checkpoint_progress_direct(
          store,
          token,
          envelope: envelope,
          now: now,
          lease_sec: lease_sec
        ) unless @context.gateway_supported?(store)

        job_id = token.fetch(:job_id)
        generation = token.fetch(:generation)
        capture = store.occurrence_capture(job_id)
        return checkpoint_progress_direct(
          store,
          token,
          envelope: envelope,
          now: now,
          lease_sec: lease_sec
        ) unless capture

        @context.gateway(entry, store, capture, now).perform!(
          sink: "discovery",
          target: "#{job_id}:checkpoint-progress",
          idempotency_key: [
            job_id,
            operation_name("checkpoint-progress"),
            generation,
            @context.digest(envelope)
          ].join(":"),
          claim_generation: generation,
          scope: { "job_id" => job_id },
          claim_validator:
            @context.claim_validator(store, token, now),
          reconcile: lambda do |_intent|
            observed = store.read_job(job_id)
            attempt = @context.discovery_attempt(
              observed, generation
            )
            progress_reconciliation(observed, attempt, envelope)
          end,
          replay: ->(_result) { store.read_job(job_id) }
        ) do
          checkpoint_progress_direct(
            store,
            token,
            envelope: envelope,
            now: now,
            lease_sec: lease_sec
          )
        end
      end

      private

      def claim_direct(store, job_id, analysis_sha:, now:, resolver:)
        store.claim_discovery!(
          job_id,
          owner: @context.owner,
          analysis_sha: analysis_sha,
          now: now,
          lease_sec: @lease_sec,
          claim_resolver: resolver,
          owner_pid: @owner_pid,
          owner_process_start_time: @owner_process_start_time
        )
      end

      def release_direct(store, token, reason:, now:, backoff_sec:)
        store.release_discovery!(
          token,
          reason: reason,
          now: now,
          backoff_sec: backoff_sec
        )
      end

      def checkpoint_direct(store, token, envelope:, now:, backoff_sec:)
        store.checkpoint_discovery!(
          token,
          envelope: envelope,
          now: now,
          backoff_sec: backoff_sec
        )
      end

      def checkpoint_progress_direct(store, token, envelope:, now:, lease_sec:)
        store.checkpoint_discovery_progress!(
          token,
          envelope: envelope,
          now: now,
          lease_sec: lease_sec
        )
      end

      def claim_resolver(aggregate, now)
        active = aggregate.fetch("attempts").reverse_each.find do |attempt|
          attempt["kind"] == JobStore::DISCOVERY_ATTEMPT_KIND &&
            @context.active_attempt?(attempt)
        end
        return @claim_resolver unless active &&
                                      Time.iso8601(
                                        active.fetch("expires_at")
                                      ) <= now

        resolved = begin
          @claim_resolver&.call(
            JSON.parse(JSON.generate(active))
          )
        rescue StandardError
          :unresolved
        end
        return unless resolved == :resolved

        ->(_claim) { :resolved }
      end

      def next_generation(aggregate)
        aggregate.fetch("attempts").filter_map do |attempt|
          attempt["generation"] if
            attempt["kind"] == JobStore::DISCOVERY_ATTEMPT_KIND
        end.max.to_i + 1
      end

      def claim_reconciliation(attempt, generation)
        if @context.owned_active_attempt?(attempt)
          {
            "status" => "matched",
            "outcome" => { "generation" => generation }
          }
        elsif attempt
          @context.ambiguous
        else
          @context.absent
        end
      end

      def release_reconciliation(aggregate, attempt, reason)
        if attempt && attempt["state"] == "released" &&
           attempt["outcome"] == reason.to_s
          @context.matched(aggregate)
        elsif @context.active_attempt?(attempt)
          @context.absent
        else
          @context.ambiguous
        end
      end

      def checkpoint_reconciliation(aggregate, attempt, envelope)
        if checkpoint_matches?(aggregate, attempt, envelope)
          @context.matched(aggregate)
        elsif @context.active_attempt?(attempt)
          @context.absent
        else
          @context.ambiguous
        end
      end

      def progress_reconciliation(aggregate, attempt, envelope)
        if @context.active_attempt?(attempt) &&
           aggregate.fetch("feature_results") ==
             envelope.fetch("feature_results")
          @context.matched(aggregate)
        elsif @context.active_attempt?(attempt)
          @context.absent
        else
          @context.ambiguous
        end
      end

      def operation_name(name)
        "#{@operation_prefix}#{name}"
      end

      def checkpoint_matches?(aggregate, attempt, envelope)
        return false unless attempt

        expected_state = envelope.fetch("complete") ?
          "complete" : "released"
        expected_outcome = if envelope.fetch("complete")
          aggregate.fetch("complete") ? "complete" : "classified"
        else
          "partial_review"
        end
        attempt["state"] == expected_state &&
          attempt["outcome"] == expected_outcome &&
          aggregate.fetch("feature_results") ==
            envelope.fetch("feature_results") &&
          JobStore::DISPOSITIONS.all? do |name|
            aggregate.dig("dispositions", name) == envelope.fetch(name)
          end
      rescue KeyError
        false
      end
    end
  end
end
