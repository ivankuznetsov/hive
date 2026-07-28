require "hive/refactor_patrol/discovery_block_transitions"
require "hive/refactor_patrol/discovery_claim_transitions"
require "hive/refactor_patrol/discovery_transition_context"

module Hive
  module RefactorPatrol
    # Facade for scheduler discovery transition collaborators.
    class DiscoveryTransitions
      def initialize(config_loader:, migration_snapshot: nil,
                     evidence_store_factory: nil, module_execution:, owner:,
                     owner_pid:, owner_process_start_time:, lease_sec:,
                     claim_resolver:, reservation_error:,
                     occurrence_lifecycle:, claimant: nil,
                     claim_operation: "discovery-claim",
                     operation_prefix: "discovery-",
                     gateway_factory: nil)
        context = DiscoveryTransitionContext.new(
          config_loader: config_loader,
          migration_snapshot: migration_snapshot,
          evidence_store_factory: evidence_store_factory,
          module_execution: module_execution,
          owner: owner,
          occurrence_lifecycle: occurrence_lifecycle,
          claimant: claimant,
          gateway_factory: gateway_factory
        )
        @claims = DiscoveryClaimTransitions.new(
          context: context,
          owner_pid: owner_pid,
          owner_process_start_time: owner_process_start_time,
          lease_sec: lease_sec,
          claim_resolver: claim_resolver,
          reservation_error: reservation_error,
          claim_operation: claim_operation,
          operation_prefix: operation_prefix
        )
        @blocks = DiscoveryBlockTransitions.new(context: context)
      end

      def claim(...)
        @claims.claim(...)
      end

      def release(...)
        @claims.release(...)
      end

      def checkpoint(...)
        @claims.checkpoint(...)
      end

      def checkpoint_progress(...)
        @claims.checkpoint_progress(...)
      end

      def block(...)
        @blocks.block(...)
      end
    end
  end
end
