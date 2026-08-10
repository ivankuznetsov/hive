module Hive
  module RefactorPatrol
    # Deterministic, in-memory claim state transitions. JobStore remains the
    # only component allowed to lock, validate, and persist the enclosing job.
    class ClaimTransitions
      def initialize(inconsistent_record:)
        @inconsistent_record = inconsistent_record
      end

      def build_discovery(attempts:, kind:, owner:, owner_pid:, owner_process_start_time:,
                          occurrence_id:, now:, lease_sec:)
        timestamp = now.utc.iso8601
        {
          "kind" => kind,
          "owner" => owner.to_s,
          "owner_pid" => owner_pid,
          "owner_process_start_time" => owner_process_start_time,
          "occurrence_id" => occurrence_id,
          "generation" => next_generation(attempts),
          "state" => "claimed",
          "transitions" => [],
          "claimed_at" => timestamp,
          "heartbeat_at" => timestamp,
          "expires_at" => (now + lease_sec.to_i).utc.iso8601,
          "pid" => nil,
          "process_start_time" => nil,
          "pgid" => nil,
          "finished_at" => nil,
          "outcome" => nil,
          "next_eligible_at" => nil
        }
      end

      def build_action(claims:, owner:, owner_pid:, owner_process_start_time:,
                       occurrence_id:, authority:, now:, lease_sec:)
        timestamp = now.utc.iso8601
        {
          "owner" => owner.to_s,
          "owner_pid" => owner_pid,
          "owner_process_start_time" => owner_process_start_time,
          "occurrence_id" => occurrence_id,
          "generation" => next_generation(claims),
          "state" => "claimed",
          "authority" => authority,
          "claimed_at" => timestamp,
          "heartbeat_at" => timestamp,
          "expires_at" => (now + lease_sec.to_i).utc.iso8601,
          "pid" => nil,
          "process_start_time" => nil,
          "pgid" => nil,
          "finished_at" => nil,
          "outcome" => nil,
          "next_eligible_at" => nil
        }
      end

      def attach_process!(claim, pid:, process_start_time:, pgid:, now:,
                          invalid_message:, lease_sec: nil)
        if pid.to_i <= 1 || pgid.to_i <= 1 || process_start_time.to_s.empty?
          raise @inconsistent_record, invalid_message
        end

        claim["state"] = "running"
        claim["pid"] = pid.to_i
        claim["process_start_time"] = process_start_time.to_s
        claim["pgid"] = pgid.to_i
        renew!(claim, now: now, lease_sec: lease_sec)
        claim
      end

      def renew!(claim, now:, lease_sec: nil)
        claim["heartbeat_at"] = now.utc.iso8601
        claim["expires_at"] = (now + lease_sec).utc.iso8601 if lease_sec
        claim
      end

      def finish!(claim, state:, outcome:, now:, next_eligible_at: nil,
                  touch_heartbeat: true)
        timestamp = now.utc.iso8601
        claim["state"] = state
        claim["heartbeat_at"] = timestamp if touch_heartbeat
        claim["finished_at"] = timestamp
        claim["outcome"] = outcome
        claim["next_eligible_at"] = next_eligible_at
        claim
      end

      private

      def next_generation(claims)
        claims.filter_map { |claim| claim["generation"] }.max.to_i + 1
      end
    end
  end
end
