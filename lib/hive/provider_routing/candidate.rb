require "hive/provider_routing"
require "hive/provider_routing/decision"

module Hive
  module ProviderRouting
    Candidate = Data.define(
      :route, :exclusions, :health, :observed_concurrency, :max_concurrency
    ) do
      def initialize(route:, exclusions:, health: nil, observed_concurrency: nil,
                     max_concurrency: nil)
        normalized = Array(exclusions).map do |entry|
          entry.is_a?(Decision::Exclusion) ? entry : Decision::Exclusion.new(**entry)
        end
        super(
          route: route,
          exclusions: normalized.freeze,
          health: health,
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
          },
          "circuits" => Array(health&.inspections).map do |inspection|
            {
              "scope" => inspection.scope.to_h,
              "status" => inspection.status,
              "generation" => inspection.generation,
              "journal_epoch" => inspection.journal_epoch,
              "state" => inspection.circuit&.automatic_state,
              "manual_block" => inspection.circuit&.blocked?,
              "eligible_at" => inspection.circuit&.eligible_at,
              "probe_owner" => inspection.circuit&.probe
            }
          end
        }.freeze
      end
    end
  end
end
