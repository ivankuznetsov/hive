require "digest"
require "hive/refactor_patrol/transition_gateway"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Shared immutable dependencies and canonical helpers for action
    # transition coordinators. It creates gateways but performs no transition.
    class ActionTransitionContext
      attr_reader :store, :capture

      def initialize(project_root:, job_store:, evidence_store:, capture:,
                     config_loader:, module_execution:, clock:, owner:,
                     gateway_factory: nil)
        @project_root = project_root
        @store = job_store
        @evidence_store = evidence_store
        @capture = capture
        @config_loader = config_loader
        @module_execution = module_execution
        @clock = clock
        @owner = owner
        @gateway_factory = gateway_factory ||
                           ->(**options) { TransitionGateway.new(**options) }
      end

      def gateway(diagnostic_transition: false)
        return unless capture
        return unless store.respond_to?(:prepare_effect!)

        @gateway_factory.call(
          project_root: @project_root,
          hive_state_path: File.join(@project_root, ".hive-state"),
          capture: capture,
          job_store: store,
          evidence_store: @evidence_store,
          config_loader: @config_loader,
          module_execution: @module_execution,
          clock: @clock,
          diagnostic_transition: diagnostic_transition
        )
      end

      def claim_validator(token, now)
        lambda do |**|
          store.assert_action_claim!(token, now: now)
        rescue JobStore::StaleClaim
          false
        end
      end

      def action_claim(job_id, action_id, generation)
        aggregate = store.read_job(job_id)
        action = find_action(aggregate, action_id)
        find_claim(action, generation)
      end

      def find_action(aggregate, action_id)
        aggregate.fetch("actions").find do |candidate|
          candidate.fetch("canonical_action_id") == action_id
        end
      end

      def find_claim(action, generation)
        Array(action && action["claims"]).find do |claim|
          claim["generation"] == generation
        end
      end

      def active_claim?(claim)
        claim && JobStore::ACTIVE_ACTION_CLAIM_STATES.include?(
          claim["state"]
        )
      end

      def action_scope(job_id, action_id)
        {
          "job_id" => job_id,
          "canonical_action_id" => action_id
        }
      end

      def digest(value)
        Digest::SHA256.hexdigest(
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        )
      end

      def absent
        { "status" => "absent", "outcome" => {} }
      end

      def ambiguous
        { "status" => "ambiguous", "outcome" => {} }
      end
    end
  end
end
