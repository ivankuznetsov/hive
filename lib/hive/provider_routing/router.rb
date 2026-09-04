require "hive/provider_routing"
require "hive/provider_routing/candidate"
require "hive/provider_routing/decision"
require "hive/provider_routing/request"

module Hive
  module ProviderRouting
    # Pure deterministic route selection from current configuration, current
    # live capacity, and the route that failed for this retry, if any.
    class Router
      def call(request:, decision_id: nil, decided_at: nil)
        unless request.is_a?(Request)
          raise ArgumentError, "provider router requires a ProviderRouting::Request"
        end
        return Decision.legacy(request: request) if request.policy.legacy?

        candidates = ordered_routes(request).map { |route| evaluate(route, request) }
        selected = candidates.find(&:eligible?)
        exclusions = candidates.flat_map(&:exclusions)
        considered = candidates.map(&:route)
        if selected
          return Decision.selected(
            request: request,
            route: selected.route,
            considered: considered,
            exclusions: exclusions,
            candidates: candidates,
            decision_id: decision_id,
            decided_at: decided_at
          )
        end

        in_boundary = candidates.select do |candidate|
          request.policy.pin_allows?(candidate.route) &&
            request.policy.requirements_satisfied?(candidate.route) &&
            candidate.route.id != configured_failed_route(request)&.id
        end
        if request.policy.pin.nil? && !in_boundary.empty? && in_boundary.all?(&:capacity_only?)
          return Decision.capacity_saturated(
            request: request,
            considered: considered,
            exclusions: exclusions,
            candidates: candidates,
            decision_id: decision_id,
            decided_at: decided_at
          )
        end

        Decision.no_route(
          request: request,
          considered: considered,
          exclusions: exclusions,
          candidates: candidates,
          decision_id: decision_id,
          decided_at: decided_at,
          reason: "no_eligible_provider_route"
        )
      end

      private

      def ordered_routes(request)
        routes = request.policy.routes
        failed = configured_failed_route(request)
        return routes unless failed

        routes.rotate(routes.index(failed) + 1)
      end

      def configured_failed_route(request)
        return unless request.failed_route_id

        request.policy.routes.find { |route| route.id == request.failed_route_id }
      end

      def evaluate(route, request)
        unless request.policy.pin_allows?(route)
          return Candidate.new(
            route: route,
            exclusions: [ exclusion(route, "hard_pin_mismatch") ]
          )
        end
        unless request.policy.requirements_satisfied?(route)
          return Candidate.new(
            route: route,
            exclusions: [ exclusion(route, "requirements_incompatible") ]
          )
        end

        if route.id == configured_failed_route(request)&.id
          return Candidate.new(
            route: route,
            exclusions: [ exclusion(route, "failed_route") ]
          )
        end

        capacity = request.capacity.fetch(route.account)
        observed = Integer(capacity.fetch("observed"))
        maximum = Integer(capacity.fetch("max"))
        raise ArgumentError unless observed >= 0 && maximum.positive?

        exclusions = []
        if observed >= maximum
          exclusions << Decision::Exclusion.new(
            route_id: route.id,
            reason: "provider_concurrency_saturated",
            detail: "#{observed}/#{maximum} live attempts"
          )
        end
        Candidate.new(
          route: route,
          exclusions: exclusions,
          observed_concurrency: observed,
          max_concurrency: maximum
        )
      rescue KeyError, ArgumentError, TypeError
        Candidate.new(
          route: route,
          exclusions: [ exclusion(route, "provider_capacity_unavailable") ]
        )
      end

      def exclusion(route, reason)
        Decision::Exclusion.new(route_id: route.id, reason: reason)
      end
    end
  end
end
