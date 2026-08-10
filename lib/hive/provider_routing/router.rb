require "hive/provider_routing"
require "hive/provider_routing/candidate"
require "hive/provider_routing/decision"
require "hive/provider_routing/request"

module Hive
  module ProviderRouting
    # Pure deterministic route selection. Health and capacity are immutable
    # observations supplied by the admission owner; this class mutates no
    # circuit, attempt, task, or recovery state.
    class Router
      def call(request:, decision_id: nil, decided_at: nil)
        unless request.is_a?(Request)
          raise ArgumentError, "provider router requires a ProviderRouting::Request"
        end
        return Decision.legacy(request: request) if request.policy.legacy?

        candidates = request.policy.routes.map { |route| evaluate(route, request) }
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
            decided_at: decided_at,
            probe_requirements: selected.health.probe_requirements,
            circuit_generations: circuit_generations(selected.health)
          )
        end

        in_boundary = candidates.select do |candidate|
          request.policy.pin_allows?(candidate.route) &&
            request.policy.requirements_satisfied?(candidate.route)
        end
        if !in_boundary.empty? && in_boundary.all?(&:capacity_only?)
          return Decision.capacity_saturated(
            request: request,
            considered: considered,
            exclusions: exclusions,
            candidates: candidates,
            decision_id: decision_id,
            decided_at: decided_at
          )
        end

        unavailable = in_boundary.any? do |candidate|
          candidate.exclusions.any? { |entry| entry.reason == "health_state_unavailable" }
        end
        Decision.no_route(
          request: request,
          considered: considered,
          exclusions: exclusions,
          candidates: candidates,
          decision_id: decision_id,
          decided_at: decided_at,
          reason: unavailable ? "health_state_unavailable" : "no_eligible_provider_route"
        )
      end

      private

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

        health = request.health.fetch(route.id)
        blockers = health.blockers.map do |blocker|
          Decision::Exclusion.new(
            route_id: route.id,
            reason: blocker.fetch("reason"),
            scope: blocker.fetch("scope"),
            observation: blocker.except("reason", "scope")
          )
        end
        capacity = request.capacity.fetch(route.account)
        observed = Integer(capacity.fetch("observed"))
        maximum = Integer(capacity.fetch("max"))
        if blockers.empty? && observed >= maximum
          blockers << Decision::Exclusion.new(
            route_id: route.id,
            reason: "provider_concurrency_saturated",
            scope: { "kind" => "provider_account", "provider_account_id" => route.account, "model" => nil },
            observation: { "observed" => observed, "max" => maximum }
          )
        end
        Candidate.new(
          route: route,
          exclusions: blockers,
          health: health,
          observed_concurrency: observed,
          max_concurrency: maximum
        )
      rescue KeyError, ArgumentError, TypeError
        Candidate.new(
          route: route,
          exclusions: [ exclusion(route, "health_state_unavailable") ]
        )
      end

      def exclusion(route, reason)
        Decision::Exclusion.new(route_id: route.id, reason: reason)
      end

      def circuit_generations(health)
        health.inspections.map do |inspection|
          {
            "scope" => inspection.scope.to_h,
            "journal_epoch" => inspection.journal_epoch,
            "observed_generation" => inspection.generation
          }
        end
      end
    end
  end
end
