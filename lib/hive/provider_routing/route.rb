require "hive/provider_routing"

module Hive
  module ProviderRouting
    Route = Data.define(
      :id, :account, :adapter, :launch_binding, :model, :effort, :order,
      :capabilities, :model_routing
    ) do
      def initialize(id:, account:, adapter:, launch_binding:, model:, effort:, order:,
                     capabilities:, model_routing: nil)
        super(
          id: ProviderRouting.frozen_string(id),
          account: ProviderRouting.frozen_string(account),
          adapter: ProviderRouting.frozen_string(adapter),
          launch_binding: ProviderRouting.frozen_string(launch_binding),
          model: ProviderRouting.frozen_string(model),
          effort: effort && ProviderRouting.frozen_string(effort),
          order: Integer(order),
          capabilities: ProviderRouting.deep_freeze(
            capabilities.to_h.transform_keys(&:to_s).transform_values do |value|
              value.is_a?(Array) ? value.map(&:to_s) : value.to_s
            end
          ),
          model_routing: model_routing
        )
        freeze
      end

      alias provider account

      def quality = capabilities.fetch("quality")
      def context = capabilities.fetch("context")
      def tools = capabilities.fetch("tools")
      def permissions = capabilities.fetch("permissions")

      def to_h
        {
          "id" => id,
          "account" => account,
          "adapter" => adapter,
          "launch_binding" => launch_binding,
          "model" => model,
          "effort" => effort,
          "order" => order,
          "capabilities" => capabilities
        }
      end
    end
  end
end
