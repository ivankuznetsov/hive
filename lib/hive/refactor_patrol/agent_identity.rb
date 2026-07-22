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
          fields: identity_fields(@cfg["refactor_patrol"]),
          parent: execute
        )
      end

      def fix
        @fix ||= inherit(
          stage: "refactor_patrol.auto_fix",
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

      def inherit(stage:, fields:, parent:)
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
          native_arguments: arguments.native_arguments
        )
      end
    end
  end
end
