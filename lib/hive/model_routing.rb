require "hive"

module Hive
  # Pure, provider-neutral model/effort routing for Hive's closed set of
  # built-in agent call identities. This module owns vocabulary, structural
  # parsing, field-wise precedence, provenance, and reachability filtering.
  # Provider selection and provider-native argument rendering live elsewhere.
  module ModelRouting
    FIELDS = %i[model effort].freeze
    CONFIG_FIELDS = FIELDS.map { |field| field.to_s.freeze }.freeze
    EFFORT_VALUES = %w[
      default
      inherit
      none
      minimal
      low
      medium
      high
      xhigh
      max
    ].map(&:freeze).freeze

    RegistryEntry = Data.define(:key, :parent) do
      def initialize(key:, parent: nil)
        super(
          key: key.to_s.dup.freeze,
          parent: parent&.to_s&.dup&.freeze
        )
        freeze
      end
    end

    Provenance = Data.define(:kind, :key) do
      ROUTED_KINDS = %i[exact coarse].freeze

      def initialize(kind:, key: nil)
        super(kind: kind.to_sym, key: key&.to_s&.dup&.freeze)
        freeze
      end

      def routed?
        ROUTED_KINDS.include?(kind)
      end
    end

    Resolution = Data.define(:stage, :provider, :model, :effort, :provenance) do
      def initialize(stage:, provider:, model:, effort:, provenance:)
        super(
          stage: stage&.to_s&.dup&.freeze,
          provider: provider,
          model: model,
          effort: effort,
          provenance: provenance.freeze
        )
        freeze
      end

      def active?
        provenance.values.any?(&:routed?)
      end
    end

    EffectiveControl = Data.define(
      :stage, :profile, :provider, :field, :value, :provenance
    ) do
      def initialize(stage:, profile:, provider:, field:, value:, provenance:)
        super(
          stage: stage.to_s.dup.freeze,
          profile: profile,
          provider: provider,
          field: field.to_sym,
          value: value,
          provenance: provenance
        )
        freeze
      end
    end

    REGISTRY = [
      RegistryEntry.new(key: "brainstorm"),
      RegistryEntry.new(key: "plan"),
      RegistryEntry.new(key: "execute"),
      RegistryEntry.new(key: "execute_implementation", parent: "execute"),
      RegistryEntry.new(key: "rebase", parent: "execute"),
      RegistryEntry.new(key: "diagnose", parent: "execute"),
      RegistryEntry.new(key: "babysitter", parent: "execute"),
      RegistryEntry.new(key: "review"),
      RegistryEntry.new(key: "review_ci", parent: "review"),
      RegistryEntry.new(key: "review_reviewers", parent: "review"),
      RegistryEntry.new(key: "review_triage", parent: "review"),
      RegistryEntry.new(key: "review_fix", parent: "review"),
      RegistryEntry.new(key: "review_browser", parent: "review"),
      RegistryEntry.new(key: "patrol"),
      RegistryEntry.new(key: "patrol_review", parent: "patrol"),
      RegistryEntry.new(key: "patrol_fix", parent: "patrol"),
      RegistryEntry.new(key: "open_pr"),
      RegistryEntry.new(key: "artifacts"),
      RegistryEntry.new(key: "finalize")
    ].freeze
    REGISTRY_BY_KEY = REGISTRY.to_h { |entry| [ entry.key, entry ] }.freeze
    EMPTY_MODELS = {}.freeze

    module_function

    def entries
      REGISTRY
    end

    def keys
      entries.map(&:key).freeze
    end

    def fetch(stage)
      key = stage.to_s
      REGISTRY_BY_KEY.fetch(key) do
        raise Hive::ConfigError,
              "unknown model-routing stage #{stage.inspect}; known stages: #{keys.inspect}"
      end
    end

    def known?(stage)
      REGISTRY_BY_KEY.key?(stage.to_s)
    end

    # Structurally validate and normalize a raw `models:` mapping. Capability
    # validation is intentionally separate because it needs the selected,
    # reachable AgentProfile after exact/coarse shadowing has been resolved.
    def parse(raw, source:)
      unless raw.is_a?(Hash)
        raise Hive::ConfigError,
              "models in #{source} must be a Hash mapping; got #{raw.inspect} (#{raw.class})"
      end

      normalized = {}
      raw.each do |raw_stage, raw_entry|
        stage = raw_stage.to_s
        entry = REGISTRY_BY_KEY[stage]
        unless entry
          raise Hive::ConfigError,
                "models.#{stage} in #{source} is unknown; known stages: #{keys.inspect}"
        end
        if normalized.key?(stage)
          raise Hive::ConfigError,
                "models.#{stage} in #{source} is defined more than once"
        end
        unless raw_entry.is_a?(Hash) && !raw_entry.empty?
          raise Hive::ConfigError,
                "models.#{stage} in #{source} must be a non-empty mapping " \
                "containing model and/or effort"
        end

        normalized_entry = {}
        raw_entry.each do |raw_field, raw_value|
          field = raw_field.to_s
          unless CONFIG_FIELDS.include?(field)
            raise Hive::ConfigError,
                  "models.#{stage} in #{source} has unknown field #{field.inspect}; " \
                  "known fields: #{CONFIG_FIELDS.inspect}"
          end
          if normalized_entry.key?(field)
            raise Hive::ConfigError,
                  "models.#{stage}.#{field} in #{source} is defined more than once"
          end

          normalized_entry[field] =
            if field == "model"
              normalize_model(raw_value, stage:, source:)
            else
              normalize_effort(raw_value, stage:, source:)
            end
        end
        normalized[stage.freeze] = normalized_entry.freeze
      end
      normalized.freeze
    end

    # Resolve model and effort independently. Exact/coarse configuration is
    # considered only when both routing configuration and stage context are
    # present. Current and legacy values are deliberately not normalized:
    # bypassed legacy callers keep their existing values and byte behavior.
    def resolve(models:, stage:, current: EMPTY_MODELS, legacy: EMPTY_MODELS, provider: nil)
      return fallback_resolution(stage, provider, current, legacy) if stage.nil?
      return fallback_resolution(stage, provider, current, legacy) if models.nil?
      if models.respond_to?(:empty?) && models.empty?
        return fallback_resolution(stage, provider, current, legacy)
      end
      unless models.is_a?(Hash)
        raise Hive::ConfigError, "models must be a mapping before model routing"
      end

      registry_entry = fetch(stage)
      stage_name = registry_entry.key
      resolved = {}
      provenance = {}
      FIELDS.each do |field|
        value, source = resolve_field(
          models, registry_entry, field, current || EMPTY_MODELS, legacy || EMPTY_MODELS
        )
        resolved[field] = value
        provenance[field] = source
      end

      Resolution.new(
        stage: stage_name,
        provider: provider,
        model: resolved.fetch(:model),
        effort: resolved.fetch(:effort),
        provenance: provenance
      )
    end

    # Project a reachable-call matrix through the resolver and yield only
    # controls whose effective value came from `models:`. Disabled calls,
    # calls without stage context, inactive maps, and shadowed coarse fields
    # never reach the capability callback.
    def validate_effective!(models:, calls:)
      return [].freeze if models.nil? || (models.respond_to?(:empty?) && models.empty?)

      controls = []
      Array(calls).each do |call|
        unless call.is_a?(Hash)
          raise ArgumentError, "reachable model-routing calls must be mappings"
        end
        next if call_value(call, :enabled) == false

        stage = call_value(call, :stage)
        next if stage.nil?

        resolution = resolve(
          models: models,
          stage: stage,
          provider: call_value(call, :provider),
          current: call_value(call, :current) || EMPTY_MODELS,
          legacy: call_value(call, :legacy) || EMPTY_MODELS
        )
        FIELDS.each do |field|
          provenance = resolution.provenance.fetch(field)
          next unless provenance.routed?

          control = EffectiveControl.new(
            stage: resolution.stage,
            profile: call_value(call, :profile),
            provider: resolution.provider,
            field: field,
            value: resolution.public_send(field),
            provenance: provenance
          )
          yield control if block_given?
          controls << control
        end
      end
      controls.freeze
    end

    def normalize_model(value, stage:, source:)
      unless value.is_a?(String) || value.is_a?(Symbol)
        raise Hive::ConfigError,
              "models.#{stage}.model in #{source} must be a non-blank scalar; " \
              "got #{value.inspect} (#{value.class})"
      end

      normalized = value.to_s.strip
      if normalized.empty?
        raise Hive::ConfigError,
              "models.#{stage}.model in #{source} must be a non-blank scalar"
      end
      normalized.freeze
    end
    private_class_method :normalize_model

    def normalize_effort(value, stage:, source:)
      normalized =
        if value.is_a?(String) || value.is_a?(Symbol)
          value.to_s.strip
        end
      return normalized.freeze if normalized && EFFORT_VALUES.include?(normalized)

      raise Hive::ConfigError,
            "models.#{stage}.effort in #{source} must be one of #{EFFORT_VALUES.inspect}; " \
            "got #{value.inspect}"
    end
    private_class_method :normalize_effort

    def fallback_resolution(stage, provider, current, legacy)
      resolved = {}
      provenance = {}
      FIELDS.each do |field|
        current_value = field_value(current, field)
        if !current_value.nil?
          resolved[field] = current_value
          provenance[field] = Provenance.new(kind: :current)
          next
        end

        legacy_value = field_value(legacy, field)
        if !legacy_value.nil?
          resolved[field] = legacy_value
          provenance[field] = Provenance.new(kind: :legacy)
        else
          resolved[field] = nil
          provenance[field] = Provenance.new(kind: :absent)
        end
      end
      Resolution.new(
        stage: stage,
        provider: provider,
        model: resolved.fetch(:model),
        effort: resolved.fetch(:effort),
        provenance: provenance
      )
    end
    private_class_method :fallback_resolution

    def resolve_field(models, registry_entry, field, current, legacy)
      exact = models_entry(models, registry_entry.key)
      if field_present?(exact, field)
        return [
          field_value(exact, field),
          Provenance.new(kind: :exact, key: registry_entry.key)
        ]
      end

      if registry_entry.parent
        coarse = models_entry(models, registry_entry.parent)
        if field_present?(coarse, field)
          return [
            field_value(coarse, field),
            Provenance.new(kind: :coarse, key: registry_entry.parent)
          ]
        end
      end

      current_value = field_value(current, field)
      return [ current_value, Provenance.new(kind: :current) ] unless current_value.nil?

      legacy_value = field_value(legacy, field)
      return [ legacy_value, Provenance.new(kind: :legacy) ] unless legacy_value.nil?

      [ nil, Provenance.new(kind: :absent) ]
    end
    private_class_method :resolve_field

    def models_entry(models, key)
      models[key] || models[key.to_sym]
    end
    private_class_method :models_entry

    def field_present?(mapping, field)
      return false unless mapping.is_a?(Hash)

      mapping.key?(field) || mapping.key?(field.to_s)
    end
    private_class_method :field_present?

    def field_value(mapping, field)
      return nil unless mapping.is_a?(Hash)
      return mapping[field] if mapping.key?(field)

      mapping[field.to_s]
    end
    private_class_method :field_value

    def call_value(call, field)
      return call[field] if call.key?(field)

      call[field.to_s]
    end
    private_class_method :call_value
  end
end
