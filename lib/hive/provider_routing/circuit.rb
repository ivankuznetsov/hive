require "time"
require "hive/provider_routing/signal"

module Hive
  module ProviderRouting
    module Circuit
      module_function

      def closed(generation: 0, now: nil, reason: nil)
        {
          "state" => "closed",
          "reason" => reason,
          "scope" => nil,
          "opened_at" => nil,
          "retry_at" => nil,
          "indefinite" => false,
          "backoff_count" => 0,
          "generation" => generation,
          "last_transition_at" => now&.utc&.iso8601,
          "safe_summary" => nil,
          "fingerprint" => nil,
          "evidence_ref" => nil,
          "probe" => nil
        }
      end

      def open(state:, signal:, account:, now:, generation:, probe_failure: false)
        now = now.utc
        backoff_count = probe_failure ? state.fetch("backoff_count", 0) + 1 : 0
        retry_at = retry_time(signal, account, now, backoff_count: backoff_count)
        {
          "state" => "open",
          "reason" => signal.failure_class,
          "scope" => signal.scope,
          "opened_at" => now.iso8601,
          "retry_at" => retry_at&.iso8601,
          "indefinite" => signal.administrative?,
          "backoff_count" => backoff_count,
          "generation" => generation,
          "last_transition_at" => now.iso8601,
          "safe_summary" => signal.safe_summary,
          "fingerprint" => signal.fingerprint,
          "evidence_ref" => signal.evidence_ref,
          "probe" => nil
        }
      end

      def probe_available?(state, now:)
        return false unless state["state"] == "open"
        return false if state["indefinite"]

        retry_at = parse_time(state["retry_at"])
        retry_at && retry_at <= now.utc
      end

      def claim_probe(state:, attempt_id:, owner:, now:, generation:)
        raise ArgumentError, "circuit is not probe-eligible" unless probe_available?(state, now: now)

        state.merge(
          "state" => "half_open",
          "generation" => generation,
          "last_transition_at" => now.utc.iso8601,
          "probe" => {
            "attempt_id" => attempt_id.to_s,
            "owner" => owner.to_s,
            "claimed_at" => now.utc.iso8601
          }
        )
      end

      def probe_matches?(state, attempt_id)
        state["state"] == "half_open" && state.dig("probe", "attempt_id") == attempt_id.to_s
      end

      def close(state:, now:, generation:, reason: "probe_succeeded")
        closed(generation: generation, now: now, reason: reason).merge(
          "scope" => state["scope"]
        )
      end

      def parse_time(value)
        value && Time.iso8601(value).utc
      rescue ArgumentError
        nil
      end

      def retry_time(signal, account, now, backoff_count:)
        return nil if signal.administrative?
        return signal.reset_at if signal.reset_at && signal.reset_at > now

        base = account.cooldown_sec.fetch(signal.failure_class)
        delay = [ base * (2**backoff_count), account.backoff_cap_sec ].min
        now + delay
      end
    end
  end
end
