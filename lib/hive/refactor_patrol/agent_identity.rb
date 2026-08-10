require "hive/agent_profiles"
require "hive/config"
require "hive/implementation_identity"
require "hive/implementation_identity/resolver"

module Hive
  module RefactorPatrol
    # Resolves architecture review and fix identities as descendants of the
    # generation's execution identity. Each layer may override agent, model,
    # and effort independently; omitted fields inherit as one coherent unit.
    class AgentIdentity
      IDENTITY_FIELDS = %w[agent model effort].freeze

      def initialize(cfg:, project_root: nil)
        @cfg = cfg || {}
        @project_root = project_root || @cfg["project_root"]
      end

      def review
        @review ||= inherit(
          stage: "refactor_patrol.review",
          routing_stage: "patrol_review",
          fields: identity_fields(@cfg["refactor_patrol"]),
          parent: execute
        )
      end

      def fix
        @fix ||= inherit(
          stage: "refactor_patrol.auto_fix",
          routing_stage: "patrol_fix",
          fields: identity_fields(@cfg.dig("refactor_patrol", "auto_fix")),
          parent: review
        )
      end

      private

      def execute
        @execute ||= Hive::ImplementationIdentity::Resolver.new(cfg: @cfg).resolve_execute(
          generation: 0, attempt_id: nil, source: "refactor_patrol_execute"
        )
      end

      def identity_fields(block)
        return {} unless block.is_a?(Hash)

        IDENTITY_FIELDS.each_with_object({}) do |field, selected|
          selected[field] = block[field] if block.key?(field)
        end
      end

      def inherit(stage:, routing_stage:, fields:, parent:)
        provider = fields.fetch("agent", parent.provider).to_s
        if provider.strip.empty?
          raise Hive::ImplementationIdentity::ResolutionError,
                "#{stage}.agent override must identify a provider"
        end

        profile = Hive::AgentProfiles.lookup(provider, cfg: @cfg)
        provider_changed = provider != parent.provider.to_s
        model = if fields.key?("model")
          Hive::ImplementationIdentity.normalize_model(fields["model"], concrete: true)
        elsif provider_changed
          profile.concrete_default_model(cfg: @cfg, project_root: @project_root)
        else
          parent.model
        end
        effort = if fields.key?("effort")
          Hive::ImplementationIdentity.normalize_effort(fields["effort"])
        else
          parent.requested_effort
        end
        resolution = Hive::ModelRouting.resolve(
          models: @cfg.fetch("models", Hive::ModelRouting::EMPTY_MODELS),
          stage: routing_stage,
          current: { model: model, effort: effort },
          provider: profile.name
        )
        if resolution.active?
          resolution = materialize_concrete_model(resolution, profile)
          profile.routing_arguments(resolution, source: routing_source)
          model = resolution.model
          effort = resolution.effort
        end
        arguments = profile.identity_arguments(model: model, effort: effort, pin_model: true)

        Hive::ImplementationIdentity::Selection.new(
          stage: stage,
          provider: profile.name,
          model: arguments.model,
          profile_name: profile.name,
          launcher_identity: profile.launcher_identity,
          source: fields.empty? ? "inherited_parent" : "explicit_override",
          generation: parent.generation,
          originating_attempt: parent.originating_attempt,
          requested_effort: arguments.requested_effort,
          effective_effort: arguments.effective_effort,
          effort_supported: arguments.effort_supported,
          model_pinned: arguments.model_pinned,
          native_arguments: resolution.active? ? [] : arguments.native_arguments,
          routing: Hive::ImplementationIdentity.routing_metadata(resolution)
        )
      end

      def materialize_concrete_model(resolution, profile)
        model =
          if Hive::ImplementationIdentity::CONCRETE_MODEL_SENTINELS.include?(
            resolution.model.to_s.downcase
          )
            profile.concrete_default_model(cfg: @cfg, project_root: @project_root)
          else
            Hive::ImplementationIdentity.normalize_model(resolution.model, concrete: true)
          end
        Hive::ModelRouting::Resolution.new(
          stage: resolution.stage,
          provider: resolution.provider,
          model: model,
          effort: resolution.effort,
          provenance: resolution.provenance
        )
      end

      def routing_source
        return "project config" if @project_root.to_s.empty?

        File.join(@project_root, ".hive-state", "config.yml")
      end
    end
  end
end
