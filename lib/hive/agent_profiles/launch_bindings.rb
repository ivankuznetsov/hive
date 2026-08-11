require "thread"

module Hive
  module AgentProfiles
    # Resolves a persisted, non-secret account binding name to an external CLI
    # configuration context only at launch. Non-default paths come from a
    # process environment binding and are never returned to durable routing
    # state, status, or logs.
    module LaunchBindings
      ENVIRONMENT_KEYS = {
        "claude" => "CLAUDE_CONFIG_DIR",
        "codex" => "CODEX_HOME",
        "pi" => "PI_CODING_AGENT_DIR",
        "grok" => "GROK_HOME"
      }.freeze
      CLEARED_CREDENTIAL_KEYS = {
        "claude" => %w[ANTHROPIC_API_KEY CLAUDE_API_KEY],
        "codex" => %w[OPENAI_API_KEY],
        "pi" => [],
        "grok" => %w[GROK_AUTH_PATH XAI_API_KEY GROK_CODE_XAI_API_KEY]
      }.freeze
      IDENTIFIER = /\A[a-z][a-z0-9_-]{0,63}\z/
      PREFLIGHT_MUTEX = Mutex.new

      Binding = Data.define(:adapter, :id, :selector_name, :environment) do
        def initialize(adapter:, id:, selector_name:, environment:)
          super(
            adapter: adapter.to_s.freeze,
            id: id.to_s.freeze,
            selector_name: selector_name&.to_s&.freeze,
            environment: environment.dup.freeze
          )
          freeze
        end

        def default? = id == "default"
      end

      module_function

      def resolve(adapter:, binding_id:, environment: ENV)
        adapter_name = adapter.to_s
        binding = binding_id.to_s
        key = ENVIRONMENT_KEYS[adapter_name]
        raise Hive::ConfigError, "provider route uses an unsupported adapter" unless key
        unless IDENTIFIER.match?(binding)
          raise Hive::ConfigError, "provider route launch binding is invalid"
        end
        selector_scrub = environment.keys.grep(/\AHIVE_PROVIDER_BINDING_/).to_h do |name|
          [ name, nil ]
        end
        if binding == "default"
          return Binding.new(
            adapter: adapter_name,
            id: binding,
            selector_name: nil,
            environment: selector_scrub
          )
        end

        selector = selector_name(adapter_name, binding)
        path = environment[selector].to_s
        unless !path.empty? && File.absolute_path?(path) && File.directory?(path)
          raise Hive::ConfigError,
                "provider launch binding #{binding.inspect} for #{adapter_name} is unavailable; " \
                "configure #{selector} as an existing absolute directory"
        end
        launch_environment = selector_scrub.merge(key => File.expand_path(path))
        CLEARED_CREDENTIAL_KEYS.fetch(adapter_name).each { |name| launch_environment[name] = nil }
        Binding.new(
          adapter: adapter_name,
          id: binding,
          selector_name: selector,
          environment: launch_environment
        )
      end

      def with_preflight_environment(binding)
        return yield if binding.nil? || binding.environment.empty?

        PREFLIGHT_MUTEX.synchronize do
          previous = binding.environment.to_h { |key, _value| [ key, ENV.key?(key) ? ENV[key] : :__missing__ ] }
          binding.environment.each do |key, value|
            value.nil? ? ENV.delete(key) : ENV[key] = value
          end
          yield
        ensure
          previous&.each do |key, value|
            value == :__missing__ ? ENV.delete(key) : ENV[key] = value
          end
        end
      end

      def selector_name(adapter, binding)
        suffix = "#{adapter}_#{binding}".upcase.tr("-", "_")
        "HIVE_PROVIDER_BINDING_#{suffix}"
      end
      private_class_method :selector_name
    end
  end
end
