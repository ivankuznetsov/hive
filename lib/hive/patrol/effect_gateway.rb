require "hive/modules/migration/effect_delivery"
require "hive/modules/migration/patrols"

module Hive
  module Patrol
    # Ordinary Patrol's product port. StateStore remains its recovery
    # authority; the shared delivery collaborator owns only the sender
    # protocol used by both patrol products.
    class EffectGateway
      Result = Hive::Modules::Migration::EffectDelivery::Result
      RETRY_SAFE_SINKS = %w[state finding review_handoff].freeze

      class Denied < StandardError
        attr_reader :reason, :receipt

        def initialize(reason, receipt)
          @reason = reason.to_s.freeze
          @receipt = receipt
          super("patrol effect denied: #{@reason}")
        end
      end

      class ReconciliationRequired < StandardError
        attr_reader :reason, :receipt

        def initialize(reason, receipt = nil)
          @reason = reason.to_s.freeze
          @receipt = receipt
          super(
            "patrol effect requires exact reconciliation: #{@reason}"
          )
        end
      end

      def initialize(project_root:, hive_state_path:, capture:, authority:,
                     evidence_store:, delivery_store:,
                     migration_lock: nil, ownership_loader: nil,
                     **options)
        project_root = File.expand_path(project_root)
        hive_state_path = File.expand_path(hive_state_path)
        @delivery = Hive::Modules::Migration::EffectDelivery.new(
          module_name: "patrol",
          product_label: "ordinary patrol",
          config_key: "patrol",
          project_root: project_root,
          hive_state_path: hive_state_path,
          capture: capture,
          authority: authority,
          evidence_store: evidence_store,
          delivery_store: delivery_store,
          denied_error: Denied,
          reconciliation_error: ReconciliationRequired,
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
              "patrol",
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

      def reconcile!(**attributes, &reconcile)
        @delivery.reconcile!(**attributes, &reconcile)
      end
    end
  end
end
