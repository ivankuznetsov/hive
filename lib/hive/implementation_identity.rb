require "json"

module Hive
  module ImplementationIdentity
    class Error < Hive::Error; end
    class InvalidIdentity < Error; end
    class ResolutionError < Error; end

    CONCRETE_MODEL_SENTINELS = %w[default inherit].freeze
    MODEL_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._:+\/@-]*\z/
    EFFORT_PATTERN = /\A[a-z][a-z0-9_-]*\z/

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

            match = line.match(/\A\s*model\s*=\s*["']([^"']+)["']\s*(?:#.*)?\z/)
            return match[1] if match
          end
        end
        nil
      end
    end
  end
end
