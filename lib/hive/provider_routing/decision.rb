require "time"
require "hive/provider_routing"
require "hive/provider_routing/request"

module Hive
  module ProviderRouting
    class Decision
      STATUSES = %i[legacy selected capacity_saturated no_route].freeze
      OWNERS = %w[attempt scheduler retry_authority operator].freeze

      Exclusion = Data.define(:route_id, :reason, :detail, :scope, :observation) do
        def initialize(route_id:, reason:, detail: nil, scope: nil, observation: nil)
          super(
            route_id: ProviderRouting.frozen_string(route_id),
            reason: ProviderRouting.frozen_string(reason),
            detail: detail && ProviderRouting.frozen_string(detail),
            scope: ProviderRouting.deep_freeze(ProviderRouting.deep_copy(scope)),
            observation: ProviderRouting.deep_freeze(ProviderRouting.deep_copy(observation))
          )
          freeze
        end

        def to_h
          {
            "route_id" => route_id,
            "reason" => reason,
            "detail" => detail,
            "scope" => scope,
            "observation" => observation
          }.freeze
        end

        # Attempt v4 deliberately persists only this bounded diagnostic subset.
        def to_record_h
          { "route_id" => route_id, "reason" => reason, "detail" => detail }.freeze
        end
      end

      attr_reader :status, :request, :route, :considered, :exclusions, :reason,
                  :policy_digest, :decision_id, :decided_at, :next_action_owner,
                  :candidates, :probe_requirements, :circuit_generations

      class << self
        def selected(request:, route:, considered:, exclusions: [], candidates: [],
                     decision_id: nil, decided_at: nil, probe_requirements: [],
                     circuit_generations: [])
          new(
            status: :selected,
            request: request,
            route: route,
            considered: considered,
            exclusions: exclusions,
            reason: "selected",
            decision_id: decision_id,
            decided_at: decided_at,
            next_action_owner: "attempt",
            candidates: candidates,
            probe_requirements: probe_requirements,
            circuit_generations: circuit_generations
          )
        end

        def no_route(request:, considered:, exclusions:, reason: "no_eligible_provider_route",
                     candidates: [], decision_id: nil, decided_at: nil,
                     next_action_owner: nil)
          owner = next_action_owner || (reason == "health_state_unavailable" ? "operator" : "retry_authority")
          new(
            status: :no_route,
            request: request,
            route: nil,
            considered: considered,
            exclusions: exclusions,
            reason: reason,
            decision_id: decision_id,
            decided_at: decided_at,
            next_action_owner: owner,
            candidates: candidates,
            probe_requirements: [],
            circuit_generations: []
          )
        end

        def capacity_saturated(request:, considered:, exclusions:, candidates: [],
                               decision_id: nil, decided_at: nil)
          new(
            status: :capacity_saturated,
            request: request,
            route: nil,
            considered: considered,
            exclusions: exclusions,
            reason: "capacity_saturated",
            decision_id: decision_id,
            decided_at: decided_at,
            next_action_owner: "scheduler",
            candidates: candidates,
            probe_requirements: [],
            circuit_generations: []
          )
        end

        def legacy(request:)
          new(
            status: :legacy,
            request: request,
            route: nil,
            considered: [],
            exclusions: [],
            reason: "legacy_bypass",
            next_action_owner: "attempt",
            candidates: [],
            probe_requirements: [],
            circuit_generations: []
          )
        end
      end

      def initialize(status:, request:, route:, considered:, exclusions:, reason:,
                     decision_id: nil, decided_at: nil, next_action_owner:,
                     candidates:, probe_requirements:, circuit_generations:)
        unless request.is_a?(Request)
          raise ArgumentError, "provider-routing decision request must be a ProviderRouting::Request"
        end
        normalized_status = status.to_sym
        raise ArgumentError, "provider-routing decision status is invalid" unless STATUSES.include?(normalized_status)
        owner = next_action_owner.to_s
        raise ArgumentError, "provider-routing next-action owner is invalid" unless OWNERS.include?(owner)

        @status = normalized_status
        @request = request
        @route = route
        @considered = Array(considered).dup.freeze
        @exclusions = Array(exclusions).map do |entry|
          entry.is_a?(Exclusion) ? entry : Exclusion.new(**entry.transform_keys(&:to_sym))
        end.freeze
        @reason = ProviderRouting.frozen_string(reason)
        @policy_digest = request.policy.digest
        @decision_id = ProviderRouting.frozen_string(
          decision_id || derived_decision_id(request, normalized_status, route, @exclusions)
        )
        @decided_at = normalize_time(decided_at || Time.at(0).utc)
        @next_action_owner = owner.freeze
        @candidates = Array(candidates).dup.freeze
        @probe_requirements = Array(probe_requirements).dup.freeze
        @circuit_generations = ProviderRouting.deep_freeze(
          ProviderRouting.deep_copy(circuit_generations)
        )
        freeze
      end

      def selected? = status == :selected
      def legacy? = status == :legacy
      def capacity_saturated? = status == :capacity_saturated
      def account = route&.account
      def provider = account
      def adapter = route&.adapter
      def model = route&.model
      def effort = route&.effort

      def to_record_h
        {
          "decision_id" => decision_id,
          "policy_digest" => policy_digest,
          "decided_at" => decided_at,
          "exclusions" => exclusions.uniq(&:route_id).map(&:to_record_h)
        }.freeze
      end

      def to_h
        {
          "decision_id" => decision_id,
          "decided_at" => decided_at,
          "task_generation" => request.task_generation,
          "policy_digest" => policy_digest,
          "status" => status.to_s,
          "reason" => reason,
          "next_action_owner" => next_action_owner,
          "policy" => {
            "stage" => request.policy.stage,
            "pin" => request.policy.pin&.to_h,
            "requirements" => request.policy.requirements.to_h
          },
          "selected_route" => route&.id,
          "candidates" => candidates.map do |candidate|
            candidate.respond_to?(:to_h) ? candidate.to_h(now: Time.iso8601(decided_at)) : candidate
          end,
          "exclusions" => exclusions.map(&:to_h),
          "circuit_generations" => circuit_generations,
          "probe_requirements" => probe_requirements.map(&:to_h)
        }.freeze
      end

      private

      def derived_decision_id(request, status, route, exclusions)
        ProviderRouting.digest(
          "task_generation" => request.task_generation,
          "policy_digest" => request.policy.digest,
          "status" => status.to_s,
          "route_id" => route&.id,
          "exclusions" => exclusions.map(&:to_record_h)
        )
      end

      def normalize_time(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6).freeze
      rescue ArgumentError
        raise ArgumentError, "provider-routing decision time must be RFC3339"
      end
    end
  end
end
