require "hive/provider_routing"
require "hive/provider_routing/decision"

module Hive
  module ProviderRouting
    Candidate = Data.define(
      :route, :exclusions, :observed_concurrency, :max_concurrency
    ) do
      def initialize(route:, exclusions:, observed_concurrency: nil,
                     max_concurrency: nil)
        normalized = Array(exclusions).map do |entry|
          entry.is_a?(Decision::Exclusion) ? entry : Decision::Exclusion.new(**entry)
        end
        super(
          route: route,
          exclusions: normalized.freeze,
          observed_concurrency: observed_concurrency.nil? ? nil : Integer(observed_concurrency),
          max_concurrency: max_concurrency.nil? ? nil : Integer(max_concurrency)
        )
        freeze
      end

      def eligible? = exclusions.empty?
      def capacity_only? = !exclusions.empty? && exclusions.all? do |entry|
        entry.reason == "provider_concurrency_saturated"
      end

      def to_h
        {
          "route_id" => route.id,
          "provider_account_id" => route.account,
          "adapter" => route.adapter,
          "model" => route.model,
          "effort" => route.effort,
          "eligible" => eligible?,
          "exclusions" => exclusions.map(&:to_h),
          "capacity" => observed_concurrency.nil? ? nil : {
            "observed" => observed_concurrency,
            "max" => max_concurrency
          }
        }.freeze
      end
    end
  end
end
