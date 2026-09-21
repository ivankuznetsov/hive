require "hive/provider_routing"
require "hive/provider_routing/policy"

module Hive
  module ProviderRouting
    Request = Data.define(:policy, :task_generation, :capacity, :failed_route_id) do
      def initialize(policy:, task_generation:, capacity: {}, failed_route_id: nil)
        unless policy.is_a?(Policy)
          raise ArgumentError, "provider-routing request policy must be a ProviderRouting::Policy"
        end

        super(
          policy: policy,
          task_generation: ProviderRouting.frozen_string(task_generation),
          capacity: ProviderRouting.deep_freeze(ProviderRouting.deep_copy(capacity)),
          failed_route_id: failed_route_id && ProviderRouting.frozen_string(failed_route_id)
        )
        freeze
      end
    end
  end
end
