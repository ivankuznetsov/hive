require "hive/provider_routing"
require "hive/provider_routing/route"

module Hive
  module ProviderRouting
    class Policy
      attr_reader :mode, :stage, :routes, :requirements, :pin, :account_policy,
                  :digest, :decision_id

      class << self
        def legacy(stage:)
          new(
            mode: :legacy,
            stage: stage,
            routes: [],
            requirements: Requirements.empty,
            pin: nil,
            account_policy: {},
            digest: nil
          )
        end

        def explicit(stage:, routes:, requirements:, pin:, account_policy:)
          ordered = Array(routes).sort_by { |route| [ route.order, route.id ] }
          payload = {
            "schema" => POLICY_SCHEMA,
            "mode" => "explicit",
            "stage" => stage.to_s,
            "routes" => ordered.map(&:to_h),
            "requirements" => requirements.to_h,
            "pin" => pin&.to_h,
            "accounts" => account_policy
          }
          new(
            mode: :explicit,
            stage: stage,
            routes: ordered,
            requirements: requirements,
            pin: pin,
            account_policy: account_policy,
            digest: ProviderRouting.digest(payload)
          )
        end
      end

      def initialize(mode:, stage:, routes:, requirements:, pin:, account_policy:, digest:)
        @mode = mode.to_sym
        @stage = ProviderRouting.frozen_string(stage)
        @routes = ProviderRouting.deep_freeze(Array(routes).dup)
        @requirements = requirements
        @pin = pin
        @account_policy = ProviderRouting.deep_freeze(
          account_policy.to_h.transform_keys(&:to_s)
        )
        @digest = digest && ProviderRouting.frozen_string(digest)
        @decision_id = @digest
        freeze
      end

      def legacy? = mode == :legacy
      def explicit? = mode == :explicit

      def eligible_routes
        return [].freeze if legacy?

        routes.select { |route| pin_allows?(route) && requirements_satisfied?(route) }.freeze
      end

      def pin_allows?(route)
        return true unless pin
        return false unless route.account == pin.provider

        pin.model.nil? || route.model == pin.model
      end

      def requirements_satisfied?(route)
        context_ok = requirements.context.nil? ||
                     CONTEXT_RANK.fetch(route.context) >= CONTEXT_RANK.fetch(requirements.context)
        quality_ok = requirements.quality.nil? ||
                     QUALITY_RANK.fetch(route.quality) >= QUALITY_RANK.fetch(requirements.quality)
        tools_ok = (requirements.tools - route.tools).empty?
        permissions_ok = (requirements.permissions - route.permissions).empty?
        context_ok && quality_ok && tools_ok && permissions_ok
      end

      def to_h
        {
          "schema" => POLICY_SCHEMA,
          "mode" => mode.to_s,
          "stage" => stage,
          "digest" => digest,
          "routes" => routes.map(&:to_h),
          "requirements" => requirements.to_h,
          "pin" => pin&.to_h,
          "accounts" => account_policy
        }
      end
    end
  end
end
