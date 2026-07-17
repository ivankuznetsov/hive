require "hive/diagnostic_helpers"
require "hive/scheduling_proof/freshness"
require "hive/scheduling_proof/reason"

module Hive
  module SchedulingProof
    class FleetProjector
      def initialize(as_of:, heartbeat_at:, poll_interval_sec:, daemon_running:,
                     unavailable_live_claims: [])
        @as_of = as_of
        @heartbeat_at = heartbeat_at
        @poll_interval_sec = poll_interval_sec
        @daemon_running = daemon_running
        @unavailable_live_claims = unavailable_live_claims
      end

      def project(configured_slots:, owners:, candidates:, prior_causal_buckets: [])
        configured = configured_slots.to_i
        owner_rows = stringify_array(owners)
        candidate_rows = distinct_candidates(candidates, owner_rows)
        errors = accounting_errors(configured, owner_rows)
        freshness = Freshness.project(
          as_of: @as_of, heartbeat_at: @heartbeat_at,
          poll_interval_sec: @poll_interval_sec, daemon_running: @daemon_running,
          unavailable_live_claims: @unavailable_live_claims
        )
        if errors.any?
          return inconsistent(configured, owner_rows, candidate_rows, errors, freshness,
                              prior_causal_buckets)
        end

        used = owner_rows.length
        unused = configured - used
        buckets = if freshness["stale"]
          stale_buckets(unused, freshness)
        else
          causal_buckets(unused, candidate_rows)
        end
        summary = "#{used}/#{configured} task slots used; #{unused} unused (#{bucket_summary(buckets)})."
        {
          "summary" => bounded(summary),
          "as_of" => freshness.fetch("as_of"),
          "configured_slots" => configured,
          "used_slots" => used,
          "unused_slots" => unused,
          "owners" => owner_rows,
          "eligible_candidate_count" => candidate_rows.count { |candidate| candidate["eligible"] == true },
          "causal_buckets" => buckets,
          "prior_causal_buckets" => stringify_array(prior_causal_buckets),
          "heartbeat_at" => freshness.fetch("scheduler_heartbeat_at"),
          "snapshot_age_sec" => freshness.fetch("snapshot_age_sec"),
          "stale" => freshness.fetch("stale"),
          "unavailable_live_claims" => freshness.fetch("unavailable_live_claims"),
          "health" => "ok",
          "accounting_errors" => [],
          "action" => { "kind" => "wait", "text" => "No fleet-level intervention is required." }
        }
      end

      private

      def distinct_candidates(candidates, owners)
        owner_keys = owners.map { |owner| task_key(owner) }
        seen = {}
        stringify_array(candidates).filter_map do |candidate|
          key = task_key(candidate)
          next if owner_keys.include?(key) || seen[key]

          seen[key] = true
          candidate
        end
      end

      def accounting_errors(configured, owners)
        errors = []
        errors << "configured_slots_invalid" if configured.negative?
        errors << "owners_exceed_configured_slots" if owners.length > configured
        errors << "duplicate_task_generation_owner" if owners.map { |owner| task_key(owner) }.uniq.length != owners.length
        errors << "duplicate_attempt_owner" if owners.filter_map { |owner| owner["attempt_id"] }.uniq.length != owners.length
        errors
      end

      def causal_buckets(unused, candidates)
        allocated = candidates.first(unused).map do |candidate|
          reason = candidate["eligible"] == true && candidate["reason"].to_s.empty? ?
            "dispatch_pending" : Reason.normalize(candidate["reason"])
          [ reason, task_ref(candidate) ]
        end
        (unused - allocated.length).times { allocated << [ "no_candidate", nil ] }
        group_allocations(allocated)
      end

      def stale_buckets(unused, freshness)
        return [] if unused.zero?

        reason = freshness["daemon_state"] == "stopped" ? "daemon_not_running" : "live_evidence_unavailable"
        [ { "reason" => reason, "units" => unused, "tasks" => [] } ]
      end

      def group_allocations(allocated)
        order = []
        grouped = {}
        allocated.each do |reason, task|
          unless grouped.key?(reason)
            order << reason
            grouped[reason] = { "reason" => reason, "units" => 0, "tasks" => [] }
          end
          grouped[reason]["units"] += 1
          grouped[reason]["tasks"] << task if task
        end
        order.map { |reason| grouped.fetch(reason) }
      end

      def inconsistent(configured, owners, candidates, errors, freshness, prior)
        {
          "summary" => bounded(Reason.summary("accounting_inconsistent")),
          "as_of" => freshness.fetch("as_of"),
          "configured_slots" => configured,
          "used_slots" => owners.length,
          "unused_slots" => nil,
          "owners" => owners,
          "eligible_candidate_count" => candidates.count { |candidate| candidate["eligible"] == true },
          "causal_buckets" => [],
          "prior_causal_buckets" => stringify_array(prior),
          "heartbeat_at" => freshness.fetch("scheduler_heartbeat_at"),
          "snapshot_age_sec" => freshness.fetch("snapshot_age_sec"),
          "stale" => true,
          "unavailable_live_claims" => (freshness.fetch("unavailable_live_claims") + [ "capacity" ]).uniq.sort,
          "health" => "accounting_inconsistent",
          "accounting_errors" => errors,
          "action" => { "kind" => "no_safe_action", "text" => "Inspect attempt ownership before scheduling or recovery." }
        }
      end

      def task_key(value)
        [ value["project"], value["task_slug"], value["stage"], value["task_generation"] ]
      end

      def task_ref(value)
        [ value["project"], value["task_slug"] ].compact.join("/")
      end

      def bucket_summary(buckets)
        return "fully utilized" if buckets.empty?

        buckets.map { |bucket| "#{bucket['reason']}=#{bucket['units']}" }.join(", ")
      end

      def bounded(value)
        Hive::DiagnosticHelpers.truncate(value.to_s.gsub(/[\r\n\t]+/, " "), Hive::DiagnosticHelpers::SUMMARY_MAX)
      end

      def stringify_array(values)
        Array(values).map do |value|
          value.to_h.to_h do |key, child|
            [ key.to_s, child.is_a?(Hash) ? child.transform_keys(&:to_s) : child ]
          end
        end
      end
    end
  end
end
