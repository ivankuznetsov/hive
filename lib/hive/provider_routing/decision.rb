require "hive/provider_routing"
require "hive/provider_routing/request"

module Hive
  module ProviderRouting
    class Decision
      Exclusion = Data.define(:route_id, :reason, :detail) do
        def initialize(route_id:, reason:, detail: nil)
          super(
            route_id: ProviderRouting.frozen_string(route_id),
            reason: ProviderRouting.frozen_string(reason),
            detail: detail && ProviderRouting.frozen_string(detail)
          )
          freeze
        end
      end

      attr_reader :status, :request, :route, :considered, :exclusions, :reason,
                  :policy_digest

      class << self
        def selected(request:, route:, considered:, exclusions: [])
          new(
            status: :selected,
            request: request,
            route: route,
            considered: considered,
            exclusions: exclusions,
            reason: "selected"
          )
        end

        def no_route(request:, considered:, exclusions:, reason: "no_eligible_route")
          new(
            status: :no_route,
            request: request,
            route: nil,
            considered: considered,
            exclusions: exclusions,
            reason: reason
          )
        end

        def legacy(request:)
          new(
            status: :legacy,
            request: request,
            route: nil,
            considered: [],
            exclusions: [],
            reason: "legacy_bypass"
          )
        end
      end

      def initialize(status:, request:, route:, considered:, exclusions:, reason:)
        unless request.is_a?(Request)
          raise ArgumentError, "provider-routing decision request must be a ProviderRouting::Request"
        end

        @status = status.to_sym
        @request = request
        @route = route
        @considered = ProviderRouting.deep_freeze(Array(considered).dup)
        @exclusions = ProviderRouting.deep_freeze(
          Array(exclusions).map do |entry|
            entry.is_a?(Exclusion) ? entry : Exclusion.new(**entry.transform_keys(&:to_sym))
          end
        )
        @reason = ProviderRouting.frozen_string(reason)
        @policy_digest = request.policy.digest
        freeze
      end

      def selected? = status == :selected
      def legacy? = status == :legacy
      def account = route&.account
      def provider = account
      def adapter = route&.adapter
      def model = route&.model
      def effort = route&.effort
    end
  end
end
