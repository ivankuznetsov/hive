require "json"

module Hive::AgentSupport::OpenCode
  class Configuration < Data.define(
    :configuration_path, :configuration, :credential_environment_keys,
    :credential_file, :plugins, :pure
  )
    OVERRIDES = {
      "config_path" => :configuration_path,
      "config" => :configuration,
      "credential_env" => :credential_environment_keys,
      "credential_file" => :credential_file,
      "plugins" => :plugins
    }.freeze

    def initialize(configuration_path: nil, configuration: nil,
                   credential_environment_keys: [], credential_file: nil,
                   plugins: [], pure: true)
      if configuration_path && configuration
        raise ArgumentError,
              "choose configuration_path or configuration, not both"
      end
      configuration = copy_configuration(configuration) if configuration
      super(
        configuration_path: configuration_path&.to_s&.dup&.freeze,
        configuration:,
        credential_environment_keys: environment_keys(credential_environment_keys),
        credential_file: credential_file&.to_s&.dup&.freeze,
        plugins: plugin_names(plugins),
        pure: pure != false
      )
    end

    def with_overrides(overrides)
      values = to_h
      overrides.each do |key, value|
        name = key.to_s
        if name == "isolation"
          unless value.to_s == "hermetic"
            raise Hive::ConfigError, "agents.opencode.isolation must be hermetic"
          end
        elsif (attribute = OVERRIDES[name])
          values[attribute] = value
        else
          known = OVERRIDES.keys + [ "isolation" ]
          raise Hive::ConfigError,
                "agents.opencode.#{key} is not a recognized override key " \
                "(known: #{known.inspect})"
        end
      end
      self.class.new(**values)
    end

    def resolve_project_paths(overrides, root:)
      overrides.to_h do |key, value|
        if %w[config_path credential_file].include?(key.to_s) &&
           !value.to_s.empty? && !File.absolute_path?(value.to_s) && !root.empty?
          [ key, File.expand_path(value.to_s, root) ]
        else
          [ key, value ]
        end
      end
    end

    def skill_options
      {
        configuration_path:,
        configuration:,
        plugins:
      }.compact
    end

    def validate_route(field:, value:, path:)
      return value unless field == :model

      AgentCliRuntime::Route.parse(value).to_s
    rescue ArgumentError => error
      raise Hive::ConfigError,
            "#{path} must be an exact OpenCode provider/model route: #{error.message}"
    end

    def identity_error(error)
      "agent profile :opencode requires an exact provider/model route: #{error.message}"
    end

    private

    def environment_keys(values)
      keys = Array(values).map { |value| value.to_s.dup.freeze }
      unless keys.all? { |key| key.match?(/\A[A-Z][A-Z0-9_]*\z/) }
        raise ArgumentError, "invalid OpenCode credential environment key"
      end
      if keys.uniq.length != keys.length
        raise ArgumentError, "OpenCode credential environment keys must be unique"
      end
      keys.freeze
    end

    def plugin_names(values)
      raise ArgumentError, "OpenCode plugins must be an array" unless values.is_a?(Array)

      names = values.map { |value| value.to_s.dup.freeze }
      raise ArgumentError, "OpenCode plugins must be non-empty strings" if names.any?(&:empty?)
      raise ArgumentError, "OpenCode plugins must be unique" if names.uniq.length != names.length

      names.freeze
    end

    def copy_configuration(value)
      raise ArgumentError, "configuration must be a Hash" unless value.is_a?(Hash)

      JSON.parse(JSON.generate(value)).tap do |copy|
        reject_credentials!(copy)
        deep_freeze(copy)
      end
    rescue JSON::GeneratorError
      raise ArgumentError, "configuration must contain JSON values"
    end

    def reject_credentials!(value, key = nil)
      case value
      when Hash
        value.each { |child_key, child| reject_credentials!(child, child_key) }
      when Array
        value.each { |child| reject_credentials!(child, key) }
      when String
        if key.to_s.match?(/(?:api[_-]?key|token|secret|password|credential)/i) &&
           !value.match?(/\A\{env:[A-Z][A-Z0-9_]*\}\z/)
          raise ArgumentError,
                "OpenCode provider definitions cannot contain credential values"
        end
      end
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| key.freeze; deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      when String
        value.freeze
      end
      value.freeze
    end
  end
end
