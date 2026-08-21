require "hive/modules/migration/effect_delivery"
require "hive/modules/migration/patrols"
require "hive/refactor_patrol/effect_errors"

module Hive
  module RefactorPatrol
    # Architecture Patrol's product port. JobStore remains its recovery and
    # action-scope authority; common sender mechanics are composed below this
    # boundary without coupling the two product gateways.
    class EffectGateway
      Result = Hive::Modules::Migration::EffectDelivery::Result
      RETRY_SAFE_SINKS = %w[job discovery action].freeze
      NotDelivered = Class.new(StandardError)
      Denied = Hive::RefactorPatrol::EffectDenied
      ReconciliationRequired =
        Hive::RefactorPatrol::EffectReconciliationRequired

      def initialize(project_root:, hive_state_path:, capture:, authority:,
                     evidence_store:, delivery_store:, claim_validator:,
                     migration_lock: nil, ownership_loader: nil,
                     **options)
        project_root = File.expand_path(project_root)
        hive_state_path = File.expand_path(hive_state_path)
        @delivery = Hive::Modules::Migration::EffectDelivery.new(
          module_name: "architecture-patrol",
          product_label: "architecture patrol",
          config_key: "refactor_patrol",
          project_root: project_root,
          hive_state_path: hive_state_path,
          capture: capture,
          authority: authority,
          evidence_store: evidence_store,
          delivery_store: delivery_store,
          denied_error: Denied,
          reconciliation_error: ReconciliationRequired,
          claim_validator: claim_validator,
          pass_intent: true,
          not_delivered_error: NotDelivered,
          migration_lock: migration_lock || lambda do |&block|
            Hive::Modules::Migration::Patrols.with_migration_lock(
              project_root,
              hive_state_path: hive_state_path,
              shared: true,
              &block
            )
          end,
          ownership_loader: ownership_loader || lambda do
            Hive::Modules::Migration::Patrols.ownership_snapshot(
              project_root,
              "architecture-patrol",
              hive_state_path: hive_state_path
            )
          end,
          retry_safe_sinks: RETRY_SAFE_SINKS,
          **options
        )
      end

      def perform!(**attributes, &effect)
        @delivery.perform!(**attributes, &effect)
      end

      def reconcile_intent!(intent, &reconcile)
        @delivery.reconcile_intent!(intent, &reconcile)
      end
    end
  end
end
