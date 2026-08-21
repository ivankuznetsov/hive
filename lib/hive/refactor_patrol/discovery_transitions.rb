require "json"
require "time"
require "hive/refactor_patrol/job_store"

module Hive
  module RefactorPatrol
    class DiscoveryTransitions
      def initialize(owner:, owner_pid:, owner_process_start_time:, lease_sec:,
                     claim_resolver:, claim_liveness_resolver: nil, **)
        @owner = owner
        @owner_pid = owner_pid
        @owner_process_start_time = owner_process_start_time
        @lease_sec = lease_sec
        @claim_resolver = claim_resolver
        @claim_liveness_resolver = claim_liveness_resolver
      end

      def claim(store:, aggregate:, analysis_sha:, now:, **)
        resolution = claim_resolution(aggregate, now)
        return unless resolution

        resolver, allow_unexpired_recovery = resolution
        store.claim_discovery!(
          aggregate.fetch("job_id"),
          owner: @owner,
          analysis_sha: analysis_sha,
          now: now,
          lease_sec: @lease_sec,
          claim_resolver: resolver,
          owner_pid: @owner_pid,
          owner_process_start_time: @owner_process_start_time,
          allow_unexpired_recovery: allow_unexpired_recovery
        )
      end

      def release(store:, token:, reason:, now:, backoff_sec:, **)
        store.release_discovery!(
          token, reason: reason, now: now, backoff_sec: backoff_sec
        )
      end

      def checkpoint(store:, token:, envelope:, now:, backoff_sec:, **)
        store.checkpoint_discovery!(
          token, envelope: envelope, now: now, backoff_sec: backoff_sec
        )
      end

      def checkpoint_progress(store:, token:, envelope:, now:, lease_sec:, **)
        store.checkpoint_discovery_progress!(
          token, envelope: envelope, now: now, lease_sec: lease_sec
        )
      end

      def block(store:, aggregate:, phase:, reason:, evidence:, now:,
                backoff_sec:, **)
        method = phase.to_sym == :action ? :block_actions! : :block_discovery!
        store.public_send(
          method, aggregate.fetch("job_id"), reason: reason,
          evidence: evidence, now: now, backoff_sec: backoff_sec
        )
      end

      def retire(store:, aggregate:, merge_sha:, trunk_sha:, now:,
                 claim_resolver: nil, **)
        store.retire_obsolete_source!(
          aggregate.fetch("job_id"), merge_sha: merge_sha,
          trunk_sha: trunk_sha, now: now, claim_resolver: claim_resolver
        )
      end

      private

      def claim_resolution(aggregate, now)
        active = aggregate.fetch("attempts").reverse_each.find do |attempt|
          attempt["kind"] == JobStore::DISCOVERY_ATTEMPT_KIND &&
            JobStore::ACTIVE_CLAIM_STATES.include?(attempt["state"])
        end
        return [ @claim_resolver, false ] unless active

        expired = Time.iso8601(active.fetch("expires_at")) <= now
        probe = expired ? @claim_resolver : @claim_liveness_resolver
        resolved = probe&.call(JSON.parse(JSON.generate(active)))
        return unless resolved == :resolved

        [ expired ? ->(_claim) { :resolved } : @claim_resolver, !expired ]
      rescue StandardError
        nil
      end
    end
  end
end
