require "hive/refactor_patrol/action_claim_transitions"
require "hive/refactor_patrol/action_plan_transitions"
require "hive/refactor_patrol/action_transition_context"

module Hive
  module RefactorPatrol
    # Facade for ActionRunner's durable transition collaborators.
    class ActionTransitions
      def initialize(project_root:, hive_state_path: nil, job_store:, evidence_store:, capture:,
                     config_loader:, module_execution:, clock:, owner:,
                     owner_pid:, owner_process_start_time:, lease_sec:,
                     claim_resolver:)
        context = ActionTransitionContext.new(
          project_root: project_root,
          hive_state_path: hive_state_path,
          job_store: job_store,
          evidence_store: evidence_store,
          capture: capture,
          config_loader: config_loader,
          module_execution: module_execution,
          clock: clock,
          owner: owner
        )
        @claims = ActionClaimTransitions.new(
          context: context,
          owner: owner,
          owner_pid: owner_pid,
          owner_process_start_time: owner_process_start_time,
          lease_sec: lease_sec,
          claim_resolver: claim_resolver
        )
        @plan = ActionPlanTransitions.new(context: context)
      end

      def claim(...)
        @claims.claim(...)
      end

      def settle(...)
        @claims.settle(...)
      end

      def initialize_actions(...)
        @plan.initialize_actions(...)
      end

      def reconcile_linked(...)
        @plan.reconcile_linked(...)
      end

      def materialize_terminal_proof(...)
        @plan.materialize_terminal_proof(...)
      end

      def record_patch_publication(...)
        @claims.record_patch_publication(...)
      end

      def record_patch_receipt(...)
        @claims.record_patch_receipt(...)
      end

      def record_publication_phase(...)
        @claims.record_publication_phase(...)
      end

      def supersede_publication(...)
        @claims.supersede_publication(...)
      end

      def record_fix_receipt(...)
        @claims.record_fix_receipt(...)
      end

      def record_creation_intent(...)
        @claims.record_creation_intent(...)
      end

      def record_action_receipt(...)
        @claims.record_action_receipt(...)
      end

      def claimed_transition(...)
        @claims.claimed_transition(...)
      end

      def block(...)
        @plan.block(...)
      end
    end
  end
end
