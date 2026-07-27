require "json"
require "hive"
require "hive/model_routing"

module Hive
  module ImplementationIdentity
    class Error < Hive::Error; end
    class InvalidIdentity < Error; end
    class ResolutionError < Error; end

    CONCRETE_MODEL_SENTINELS = %w[default inherit].freeze
    MODEL_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._:+\/@-]*\z/
    EFFORT_PATTERN = /\A[a-z][a-z0-9_-]*\z/
    ROUTING_PROVENANCE_KINDS = %w[exact coarse current legacy absent].freeze

    LaunchArguments = Data.define(
      :model, :requested_effort, :effective_effort, :effort_supported,
      :model_pinned, :native_arguments
    ) do
      def initialize(model:, requested_effort:, effective_effort:, effort_supported:,
                     model_pinned:, native_arguments:)
        super(
          model: model&.dup&.freeze,
          requested_effort: requested_effort&.dup&.freeze,
          effective_effort: effective_effort&.dup&.freeze,
          effort_supported: effort_supported == true,
          model_pinned: model_pinned == true,
          native_arguments: Array(native_arguments).map { |arg| arg.to_s.dup.freeze }.freeze
        )
      end
    end

    Selection = Data.define(
      :stage, :provider, :model, :profile_name, :launcher_identity, :source,
      :generation, :originating_attempt, :requested_effort, :effective_effort,
      :effort_supported, :model_pinned, :native_arguments, :routing
    ) do
      def initialize(stage:, provider:, model:, profile_name:, launcher_identity:, source:,
                     generation:, originating_attempt:, requested_effort:, effective_effort:,
                     effort_supported:, model_pinned:, native_arguments:, routing: nil)
        routing = Hive::ImplementationIdentity.normalize_routing_metadata(routing)
        if routing
          unless model.to_s == routing.fetch("model")
            raise InvalidIdentity, "durable model does not match frozen routing metadata"
          end
          unless requested_effort&.to_s == routing["effort"]
            raise InvalidIdentity, "durable effort does not match frozen routing metadata"
          end
        end
        super(
          stage: stage.to_s.freeze,
          provider: provider.to_s.freeze,
          model: model.to_s.freeze,
          profile_name: profile_name.to_s.freeze,
          launcher_identity: launcher_identity.to_s.freeze,
          source: source.to_s.freeze,
          generation: Integer(generation),
          originating_attempt: originating_attempt&.to_s&.freeze,
          requested_effort: requested_effort&.to_s&.freeze,
          effective_effort: effective_effort&.to_s&.freeze,
          effort_supported: effort_supported == true,
          model_pinned: model_pinned == true,
          native_arguments: (
            routing ? [] : Hive::ImplementationIdentity.validate_native_arguments(native_arguments)
          ).map { |arg| arg.to_s.dup.freeze }.freeze,
          routing: routing
        )
      end

      def to_h
        members.to_h { |member| [ member.to_s, public_send(member) ] }
               .reject { |key, value| key == "routing" && value.nil? }
      end

      def routing_resolution
        return nil unless routing

        Hive::ImplementationIdentity.routing_resolution_from_metadata(
          routing, provider: provider
        )
      end

      def routing_arguments(profile, source: "stored implementation identity")
        resolution = routing_resolution
        return nil unless resolution

        profile.routing_arguments(resolution, source: source)
      end
    end

    module_function

    def normalize_model(model, concrete: false)
      value = model.to_s.strip
      if value.empty? || !MODEL_PATTERN.match?(value)
        raise InvalidIdentity, "model must be a non-empty provider model identifier"
      end
      if concrete && CONCRETE_MODEL_SENTINELS.include?(value.downcase)
        raise ResolutionError, "provider did not resolve a concrete default model (got #{value.inspect})"
      end

      value.freeze
    end

    def normalize_effort(effort)
      return nil if effort.nil? || effort.to_s.strip.empty?

      value = effort.to_s.strip
      unless EFFORT_PATTERN.match?(value)
        raise InvalidIdentity, "effort must be a lowercase provider effort identifier"
      end

      value.freeze
    end

    def validate_native_arguments(arguments)
      Array(arguments).map do |argument|
        value = argument.to_s
        if value.empty? || value.include?("\0") || value.match?(/[\r\n]/)
          raise InvalidIdentity, "native identity arguments must be non-empty discrete argv values"
        end
        value
      end
    end

    def routing_metadata(resolution)
      return nil unless resolution&.active?

      normalize_routing_metadata(
        "stage" => resolution.stage,
        "model" => resolution.model,
        "effort" => resolution.effort,
        "provenance" => resolution.provenance.to_h do |field, provenance|
          [
            field.to_s,
            {
              "kind" => provenance.kind.to_s,
              "key" => provenance.key
            }.compact
          ]
        end
      )
    end

    def normalize_routing_metadata(value)
      return nil if value.nil?
      raise InvalidIdentity, "routing metadata must be a mapping" unless value.is_a?(Hash)

      stage = routing_value(value, "stage").to_s
      begin
        entry = Hive::ModelRouting.fetch(stage)
      rescue Hive::ConfigError => e
        raise InvalidIdentity, e.message
      end
      model = normalize_model(routing_value(value, "model"), concrete: true)
      effort = normalize_effort(routing_value(value, "effort"))
      raw_provenance = routing_value(value, "provenance")
      unless raw_provenance.is_a?(Hash)
        raise InvalidIdentity, "routing metadata provenance must be a mapping"
      end

      provenance = Hive::ModelRouting::FIELDS.to_h do |field|
        raw = routing_value(raw_provenance, field.to_s)
        unless raw.is_a?(Hash)
          raise InvalidIdentity, "routing metadata requires #{field} provenance"
        end

        kind = routing_value(raw, "kind").to_s
        unless ROUTING_PROVENANCE_KINDS.include?(kind)
          raise InvalidIdentity, "unknown routing provenance #{kind.inspect} for #{field}"
        end
        key = routing_value(raw, "key")
        key = key.to_s unless key.nil?
        expected_key =
          case kind
          when "exact" then entry.key
          when "coarse" then entry.parent
          end
        if %w[exact coarse].include?(kind)
          unless expected_key && key == expected_key
            raise InvalidIdentity,
                  "routing provenance #{kind} for #{field} must name #{expected_key.inspect}"
          end
        elsif key
          raise InvalidIdentity, "routing provenance #{kind} for #{field} may not name a config key"
        end

        [
          field.to_s.freeze,
          {
            "kind" => kind.freeze,
            **({ "key" => key.freeze } if key)
          }.freeze
        ]
      end.freeze
      unless provenance.values.any? { |source| %w[exact coarse].include?(source.fetch("kind")) }
        raise InvalidIdentity, "routing metadata must contain an exact or coarse control"
      end

      {
        "stage" => entry.key,
        "model" => model,
        "effort" => effort,
        "provenance" => provenance
      }.freeze
    end

    def routing_resolution_from_metadata(metadata, provider:)
      value = normalize_routing_metadata(metadata)
      provenance = value.fetch("provenance").to_h do |field, source|
        [
          field.to_sym,
          Hive::ModelRouting::Provenance.new(
            kind: source.fetch("kind"),
            key: source["key"]
          )
        ]
      end
      Hive::ModelRouting::Resolution.new(
        stage: value.fetch("stage"),
        provider: provider,
        model: value.fetch("model"),
        effort: value["effort"],
        provenance: provenance
      )
    end

    def routing_value(mapping, key)
      return mapping[key] if mapping.key?(key)

      mapping[key.to_sym]
    end
    private_class_method :routing_value

    # Read only provider-owned configuration files. These helpers deliberately
    # extract only model/provider identifiers; credentials and unrelated CLI
    # settings never enter the normalized identity.
    module NativeDefaults
      module_function

      def resolve(provider, project_root: nil, home: nil, **)
        home ||= Dir.home
        value = case provider.to_sym
        when :claude
          json_model(paths(project_root, home, ".claude/settings.json"), %w[model])
        when :codex
          toml_model(paths(project_root, home, ".codex/config.toml"))
        when :pi
          pi_model(paths(project_root, home, ".pi/settings.json", home_relative: ".pi/agent/settings.json"))
        when :grok
          json_model(paths(project_root, home, ".grok/settings.json"), %w[model defaultModel]) ||
            toml_model(paths(project_root, home, ".grok/config.toml"))
        else
          raise ResolutionError, "unknown provider #{provider.inspect}"
        end

        if value.to_s.strip.empty?
          raise ResolutionError, "#{provider} did not expose a concrete default model"
        end
        Hive::ImplementationIdentity.normalize_model(value, concrete: true)
      rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError, ArgumentError => e
        raise ResolutionError, "could not inspect #{provider} default model: #{e.message}"
      end

      def paths(project_root, home, project_relative, home_relative: project_relative)
        values = []
        values << File.join(project_root, project_relative) unless project_root.to_s.empty?
        values << File.join(home, home_relative) unless home.to_s.empty?
        values.uniq
      end

      def json_model(candidate_paths, keys)
        candidate_paths.each do |path|
          next unless File.file?(path)

          data = JSON.parse(File.binread(path))
          next unless data.is_a?(Hash)

          keys.each do |key|
            value = data[key]
            return value unless value.to_s.strip.empty?
          end
        end
        nil
      end

      def pi_model(candidate_paths)
        candidate_paths.each do |path|
          next unless File.file?(path)

          data = JSON.parse(File.binread(path))
          next unless data.is_a?(Hash)

          model = data["model"] || data["defaultModel"]
          next if model.to_s.strip.empty?

          provider = data["provider"] || data["defaultProvider"]
          return model if provider.to_s.empty? || model.to_s.include?("/")

          return "#{provider}/#{model}"
        end
        nil
      end

      def toml_model(candidate_paths)
        candidate_paths.each do |path|
          next unless File.file?(path)

          File.foreach(path) do |line|
            next if line.lstrip.start_with?("#")
            break if line.lstrip.start_with?("[")

            match = line.match(/\A\s*model\s*=\s*["']([^"']+)["']\s*(?:#.*)?\s*\z/)
            return match[1] if match
          end
        end
        nil
      end
    end
  end
end
