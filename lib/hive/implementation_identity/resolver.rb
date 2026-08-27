require "hive/agent_profiles"
require "hive/config"
require "hive/implementation_identity"
require "hive/implementation_identity/utility_models"
require "hive/model_routing"
require "hive/provider_routing/route"

module Hive
  module ImplementationIdentity
    class Resolver
      DOWNSTREAM_EFFORT = {
        "open_pr" => "medium",
        "review.fix" => "high",
        "review.ci" => "high"
      }.freeze
      ROUTING_STAGES = {
        "execute" => "execute_implementation",
        "open_pr" => "open_pr",
        "review.fix" => "review_fix",
        "review.ci" => "review_ci"
      }.freeze
      IMPLEMENTATION_STAGES = ROUTING_STAGES.keys.freeze

      def initialize(cfg:)
        @cfg = cfg || {}
      end

      def resolve_execute(generation:, attempt_id:, source: "persisted_execute", route: nil)
        if route
          return resolve_execute_route(
            route,
            generation: generation,
            attempt_id: attempt_id,
            source: source
          )
        end

        fields = Hive::Config.implementation_identity_fields(@cfg, "execute")
        provider = identity_field(fields, "agent") || @cfg.dig("execute", "agent")
        if provider.to_s.strip.empty?
          raise ResolutionError, "execute.agent must identify an implementation provider"
        end

        profile = Hive::AgentProfiles.lookup(provider, cfg: @cfg)
        routing_stage = ROUTING_STAGES.fetch("execute")
        model =
          if routed_field?(routing_stage, :model)
            nil
          elsif fields.key?("model")
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
          originating_attempt: attempt_id,
          routing_stage: routing_stage
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

        routing_stage = ROUTING_STAGES.fetch(stage)
        model, pin_model =
          if routed_field?(routing_stage, :model)
            [ nil, true ]
          else
            downstream_model(
              stage, fields: fields, profile: profile, provider_changed: provider_changed,
              execute_identity: execute_identity
            )
          end
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
          originating_attempt: attempt_id || identity_value(execute_identity, :originating_attempt),
          routing_stage: routing_stage
        )
      end

      # Single authority for materializing one persisted identity projection
      # back into a live Selection. Routed selections carry no native argv —
      # their frozen routing metadata is replayed through routing_arguments —
      # while legacy flat identities re-derive typed arguments from their
      # profile. This mirrors build_selection's routed-versus-flat
      # representation so Store and Reconstructor cannot diverge from it.
      def materialize_persisted(identity)
        profile = Hive::AgentProfiles.lookup(identity.fetch("provider"), cfg: @cfg)
        routing = identity["routing"]
        native_arguments =
          if routing
            []
          else
            profile.identity_arguments(
              model: identity.fetch("model"), effort: identity["requested_effort"],
              pin_model: identity.fetch("model_pinned", true)
            ).native_arguments
          end
        selection = Selection.new(
          stage: identity.fetch("stage"), provider: identity.fetch("provider"),
          model: identity.fetch("model"), profile_name: identity.fetch("profile_name"),
          launcher_identity: identity.fetch("launcher_identity"), source: identity.fetch("source"),
          generation: identity.fetch("generation"),
          originating_attempt: identity["originating_attempt"],
          requested_effort: identity["requested_effort"],
          effective_effort: identity["effective_effort"],
          effort_supported: identity["effort_supported"],
          model_pinned: identity.fetch("model_pinned", true),
          native_arguments: native_arguments,
          routing: routing
        )
        selection.routing_arguments(profile) if routing
        selection
      end

      def resolve_legacy(provider:, model:, effort:, generation:, attempt_id:)
        profile = Hive::AgentProfiles.lookup(provider, cfg: @cfg)
        build_selection(
          stage: "execute", profile: profile,
          model: Hive::ImplementationIdentity.normalize_model(model, concrete: true),
          effort: Hive::ImplementationIdentity.normalize_effort(effort),
          pin_model: true, source: "legacy_backfill", generation: generation,
          originating_attempt: attempt_id, routing_stage: nil
        )
      end

      private

      # Project an admitted provider-account route into the existing durable
      # identity. The provider field deliberately remains the adapter/profile;
      # the account and launch binding belong to the attempt route context.
      def resolve_execute_route(route, generation:, attempt_id:, source:)
        unless route.is_a?(Hive::ProviderRouting::Route)
          raise ResolutionError, "explicit execute route must be a ProviderRouting::Route"
        end

        profile = Hive::AgentProfiles.lookup(route.adapter, cfg: @cfg)
        arguments = profile.identity_arguments(
          model: route.model,
          effort: route.effort,
          pin_model: true
        )
        Selection.new(
          stage: "execute",
          provider: profile.name,
          model: arguments.model,
          profile_name: profile.name,
          launcher_identity: profile.launcher_identity,
          source: source,
          generation: generation,
          originating_attempt: attempt_id,
          requested_effort: arguments.requested_effort,
          effective_effort: arguments.effective_effort,
          effort_supported: arguments.effort_supported,
          model_pinned: true,
          native_arguments: arguments.native_arguments,
          routing: Hive::ImplementationIdentity.routing_metadata(route.model_routing)
        )
      end

      def downstream_model(stage, fields:, profile:, provider_changed:, execute_identity:)
        if fields.key?("model")
          return [ Hive::ImplementationIdentity.normalize_model(fields["model"], concrete: true), true ]
        end

        support = Hive::AgentSupport.for(profile)
        selected = support.downstream_model(
          stage:, execute_identity:, provider_changed:
        ) if support&.respond_to?(:downstream_model)
        return selected if selected

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
                          generation:, originating_attempt:, routing_stage:)
        resolution = routing_resolution(
          routing_stage, profile: profile, model: model, effort: effort
        )
        if resolution&.active?
          Hive::ModelRouting.validate_effective!(
            models: @cfg.fetch("models", Hive::ModelRouting::EMPTY_MODELS),
            calls: [
              {
                stage: routing_stage,
                profile: profile,
                provider: profile.name,
                current: { model: model, effort: effort }
              }
            ]
          ) do |control|
            profile.validate_routed_control!(control, source: routing_source)
          end
          resolution = materialize_concrete_routed_model(resolution, profile)
          profile.routing_arguments(resolution, source: routing_source)
          arguments = profile.identity_arguments(
            model: resolution.model, effort: resolution.effort, pin_model: true
          )
          return Selection.new(
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
            model_pinned: true,
            native_arguments: [],
            routing: Hive::ImplementationIdentity.routing_metadata(resolution)
          )
        end

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
          native_arguments: arguments.native_arguments,
          routing: nil
        )
      end

      def routing_resolution(stage, profile:, model:, effort:)
        return nil unless stage

        Hive::ModelRouting.resolve(
          models: @cfg.fetch("models", Hive::ModelRouting::EMPTY_MODELS),
          stage: stage,
          current: { model: model, effort: effort },
          provider: profile.name
        )
      end

      def routed_field?(stage, field)
        resolution = Hive::ModelRouting.resolve(
          models: @cfg.fetch("models", Hive::ModelRouting::EMPTY_MODELS),
          stage: stage
        )
        resolution.provenance.fetch(field).routed?
      end

      def materialize_concrete_routed_model(resolution, profile)
        model = resolution.model
        if Hive::ImplementationIdentity::CONCRETE_MODEL_SENTINELS.include?(
          model.to_s.downcase
        )
          model = profile.concrete_default_model(
            cfg: @cfg, project_root: @cfg["project_root"]
          )
        else
          model = Hive::ImplementationIdentity.normalize_model(model, concrete: true)
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
        root = @cfg["project_root"].to_s
        return "project config" if root.empty?

        File.join(root, ".hive-state", "config.yml")
      end

      def configured_model(profile)
        support = Hive::AgentSupport.for(profile)
        return nil unless support&.respond_to?(:legacy_control)

        value = support.legacy_control(@cfg, :model).to_s.strip
        return nil if value.empty? || %w[default inherit].include?(value)

        Hive::ImplementationIdentity.normalize_model(value, concrete: true)
      end

      def configured_effort(profile)
        support = Hive::AgentSupport.for(profile)
        return nil unless support&.respond_to?(:legacy_control)

        value = support.legacy_control(@cfg, :effort).to_s.strip
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
