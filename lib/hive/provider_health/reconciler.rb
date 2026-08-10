require "hive/provider_health/store"

module Hive
  module ProviderHealth
    # Restart seam for unfinished multi-scope probe intents. Attempt ownership
    # remains authoritative; this adapter merely asks the store to finish or
    # conservatively roll back its health-side intent.
    class Reconciler
      def initialize(store:)
        raise InvalidMutation, "provider-health reconciler requires a Store" unless store.is_a?(Store)

        @store = store
      end

      def call
        @store.reconcile!
      end
    end
  end
end
