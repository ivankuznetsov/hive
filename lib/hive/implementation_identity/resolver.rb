require "hive/agent_profiles"
require "hive/config"
require "hive/implementation_identity"
require "hive/implementation_identity/utility_models"

module Hive
  module ImplementationIdentity
    class Resolver
      DOWNSTREAM_EFFORT = {
        "open_pr" => "medium",
        "review.fix" => "high",
        "review.ci" => "high"
      }.freeze
      IMPLEMENTATION_STAGES = [ "execute", *DOWNSTREAM_EFFORT.keys ].freeze

      def initialize(cfg:)
        @cfg = cfg || {}
      end

      def resolve_execute(generation:, attempt_id:, source: "persisted_execute")
        fields = Hive::Config.implementation_identity_fields(@cfg, "execute")
        provider = identity_field(fields, "agent") || @cfg.dig("execute", "agent")
        if provider.to_s.strip.empty?
          raise ResolutionError, "execute.agent must identify an implementation provider"
        end

        profile = Hive::AgentProfiles.lookup(provider, cfg: @cfg)
        model = if fields.key?("model")
          Hive::ImplementationIdentity.normalize_model(fields["model"], concrete: true)
        else
          configured_model(profile) || profile.concrete_default_model(
            cfg: @cfg, project_root: @cfg["project_root"]
          )
        end
        effort = if fields.key?("effort")
          Hive::ImplementationIdentity.normalize_effort(fields["effort"])
        else
          configured_effort(profile)
        end

        build_selection(
          stage: "execute", profile: profile, model: model, effort: effort,
          pin_model: true, source: source, generation: generation,
          originating_attempt: attempt_id
        )
      end

      def resolve_stage(stage, execute_identity:, attempt_id: nil)
        stage = stage.to_s
        unless DOWNSTREAM_EFFORT.key?(stage)
          raise ResolutionError, "#{stage.inspect} is not an implementation-owning downstream stage"
        end

        fields = Hive::Config.implementation_identity_fields(@cfg, stage)
        execute_provider = identity_value(execute_identity, :provider)
        provider = fields.key?("agent") ? fields["agent"] : execute_provider
        if provider.to_s.strip.empty?
          raise ResolutionError, "#{stage}.agent override must identify a provider"
        end
        profile = Hive::AgentProfiles.lookup(provider, cfg: @cfg)
        provider_changed = provider.to_s != execute_provider.to_s

        model, pin_model = downstream_model(
          stage, fields: fields, profile: profile, provider_changed: provider_changed,
          execute_identity: execute_identity
        )
        effort = if fields.key?("effort")
          Hive::ImplementationIdentity.normalize_effort(fields["effort"])
        else
          DOWNSTREAM_EFFORT.fetch(stage)
        end
        source = if fields.empty?
          identity_value(execute_identity, :source).to_s == "legacy_backfill" ?
            "legacy_backfill" : "persisted_execute"
        else
          "explicit_override"
        end

        build_selection(
          stage: stage, profile: profile, model: model, effort: effort,
          pin_model: pin_model, source: source,
          generation: identity_value(execute_identity, :generation),
          originating_attempt: attempt_id || identity_value(execute_identity, :originating_attempt)
        )
      end

      def resolve_legacy(provider:, model:, effort:, generation:, attempt_id:)
        profile = Hive::AgentProfiles.lookup(provider, cfg: @cfg)
        build_selection(
          stage: "execute", profile: profile,
          model: Hive::ImplementationIdentity.normalize_model(model, concrete: true),
          effort: Hive::ImplementationIdentity.normalize_effort(effort),
          pin_model: true, source: "legacy_backfill", generation: generation,
          originating_attempt: attempt_id
        )
      end

      private

      def downstream_model(stage, fields:, profile:, provider_changed:, execute_identity:)
        if fields.key?("model")
          return [ Hive::ImplementationIdentity.normalize_model(fields["model"], concrete: true), true ]
        end

        if stage == "open_pr"
          policy = UtilityModels.resolve(profile.name)
          model = policy.fetch(:model) || profile.concrete_default_model(
            cfg: @cfg, project_root: @cfg["project_root"]
          )
          return [ model, policy.fetch(:pin_model) ]
        end

        if provider_changed
          return [ profile.concrete_default_model(
            cfg: @cfg, project_root: @cfg["project_root"]
          ), true ]
        end

        [ identity_value(execute_identity, :model), true ]
      end

      def build_selection(stage:, profile:, model:, effort:, pin_model:, source:,
                          generation:, originating_attempt:)
        arguments = profile.identity_arguments(
          model: model, effort: effort, pin_model: pin_model
        )
        Selection.new(
          stage: stage,
          provider: profile.name,
          model: arguments.model,
          profile_name: profile.name,
          launcher_identity: profile.launcher_identity,
          source: source,
          generation: generation,
          originating_attempt: originating_attempt,
          requested_effort: arguments.requested_effort,
          effective_effort: arguments.effective_effort,
          effort_supported: arguments.effort_supported,
          model_pinned: arguments.model_pinned,
          native_arguments: arguments.native_arguments
        )
      end

      def configured_model(profile)
        return nil unless profile.name == :claude

        value = @cfg.dig("claude", "model").to_s.strip
        return nil if value.empty? || %w[default inherit].include?(value)

        Hive::ImplementationIdentity.normalize_model(value, concrete: true)
      end

      def configured_effort(profile)
        return nil unless profile.name == :claude

        value = @cfg.dig("claude", "effort").to_s.strip
        return nil if value.empty? || %w[default inherit].include?(value)

        Hive::ImplementationIdentity.normalize_effort(value)
      end

      def identity_field(fields, name)
        return nil unless fields.key?(name)

        fields[name]
      end

      def identity_value(identity, name)
        return identity.public_send(name) if identity.respond_to?(name)

        identity[name.to_s] || identity[name.to_sym]
      end
    end
  end
end
