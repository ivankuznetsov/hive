require "hive/refactor_patrol/job_store"

module Hive
  module RefactorPatrol
    # Narrow operational port for claim-process attachment and heartbeat
    # renewal. These updates do not represent product outcomes and therefore
    # do not create occurrence effects, but they remain generation/lease
    # fenced by JobStore and cannot be invoked directly by command or daemon
    # composition roots.
    class ClaimMaintenanceTransitions
      def attach_discovery(store:, token:, pid:, process_start_time:, pgid:,
                           now:, lease_sec:)
        store.attach_discovery_process!(
          token,
          pid: pid,
          process_start_time: process_start_time,
          pgid: pgid,
          now: now,
          lease_sec: lease_sec
        )
      end

      def renew(store:, token:, now:, lease_sec:, claim_resolver:)
        case token.fetch(:kind).to_sym
        when :discovery
          store.renew_discovery_claim!(
            token,
            now: now,
            lease_sec: lease_sec,
            claim_resolver: claim_resolver
          )
        when :action
          store.renew_action_claim!(
            token,
            now: now,
            lease_sec: lease_sec,
            claim_resolver: claim_resolver
          )
        else
          raise JobStore::InconsistentRecord,
                "refactor patrol claim kind is unsupported"
        end
      end
    end
  end
end
