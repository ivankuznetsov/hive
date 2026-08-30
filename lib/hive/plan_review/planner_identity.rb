require "hive/agent_profiles"
require "hive/agent_support"
require "hive/model_routing"

module Hive
  module PlanReview
    module PlannerIdentity
      CONTRACT_VERSION = 1
      FAMILIES = {
        claude: "anthropic", codex: "openai", grok: "grok", pi: "pi"
      }.freeze

      module_function

      def capture(profile:, cfg:, observed_model: nil, reconstructed: false)
        resolution = Hive::ModelRouting.resolve(
          models: cfg.fetch("models", Hive::ModelRouting::EMPTY_MODELS),
          stage: "plan", provider: profile.name,
          current: values(cfg["plan"]), legacy: legacy_values(profile, cfg),
        )
        model = observed_model.to_s.strip
        model = (resolution.model || "default").to_s if model.empty?
        identity = {
          "provider" => profile.name.to_s,
          "model" => model,
          "family" => family(profile.name),
          "effort" => (resolution.effort || "default").to_s,
          "route" => profile.launcher_identity.to_s
        }
        identity["reconstructed"] = true if reconstructed
        identity.freeze
      end

      # Old plan-review adoption used claude.model as a fallback even when the
      # captured planner provider was Codex. That produced an impossible
      # codex/claude-* pair which every planner revision retried forever.
      def recoverable?(identity)
        row = stringify(identity)
        support = Hive::AgentSupport.for(row["provider"])
        support&.respond_to?(:recoverable_planner_identity?) &&
          support.recoverable_planner_identity?(row)
      end

      def repair(identity, cfg:)
        return unless recoverable?(identity)

        row = stringify(identity)
        profile = Hive::AgentProfiles.lookup(row.fetch("provider"), cfg:)
        row.merge(
          "model" => "default",
          "family" => family(profile.name),
          "effort" => normalized_effort(row["effort"]),
          "route" => profile.launcher_identity.to_s,
          "reconstructed" => true
        ).freeze
      end

      def family(provider)
        FAMILIES.fetch(provider.to_sym, "unknown")
      end

      def values(block)
        return Hive::ModelRouting::EMPTY_MODELS unless block.is_a?(Hash)

        {
          model: block["model"] || block[:model],
          effort: block["effort"] || block[:effort]
        }.compact
      end
      private_class_method :values

      def legacy_values(profile, cfg)
        support = Hive::AgentSupport.for(profile)
        return Hive::ModelRouting::EMPTY_MODELS unless support&.respond_to?(:legacy_control)

        {
          model: support.legacy_control(cfg, :model),
          effort: support.legacy_control(cfg, :effort)
        }.compact
      end
      private_class_method :legacy_values

      def normalized_effort(value)
        effort = value.to_s.strip
        effort.empty? || effort == "unknown" ? "default" : effort
      end
      private_class_method :normalized_effort

      def stringify(value)
        return {} unless value.respond_to?(:to_h)

        value.to_h { |key, child| [ key.to_s, child ] }
      end
      private_class_method :stringify
    end
  end
end
