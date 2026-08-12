require "hive/provider_routing"
require "hive/provider_routing/policy"

module Hive
  module ProviderRouting
    Request = Data.define(:policy, :task_generation, :health, :capacity) do
      def initialize(policy:, task_generation:, health: {}, capacity: {})
        unless policy.is_a?(Policy)
          raise ArgumentError, "provider-routing request policy must be a ProviderRouting::Policy"
        end

        super(
          policy: policy,
          task_generation: ProviderRouting.frozen_string(task_generation),
          health: ProviderRouting.deep_freeze(ProviderRouting.deep_copy(health)),
          capacity: ProviderRouting.deep_freeze(ProviderRouting.deep_copy(capacity))
        )
        freeze
      end
    end
  end
end
