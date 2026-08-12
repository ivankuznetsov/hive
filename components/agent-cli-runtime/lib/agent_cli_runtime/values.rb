module AgentCliRuntime
  module Immutable
    module_function

    def string(value)
      string = value.to_s
      string.frozen? ? string : string.dup.freeze
    end

    def strings(values)
      Array(values).map { |value| string(value) }.freeze
    end

    def symbols(values)
      Array(values).map(&:to_sym).uniq.freeze
    end

    def hash(value)
      unless value.is_a?(Hash)
        raise ArgumentError, "value must be a Hash"
      end

      value.each_with_object({}) do |(key, item), result|
        result[string(key)] = deep(item)
      end.freeze
    end

    def deep(value)
      case value
      when Hash then hash(value)
      when Array then value.map { |item| deep(item) }.freeze
      when String then string(value)
      when Symbol, Numeric, TrueClass, FalseClass, NilClass then value
      else
        raise ArgumentError,
              "unsupported immutable value #{value.class}"
      end
    end
  end
  private_constant :Immutable

  CapabilityEvidence = Data.define(
    :capability, :supported, :provider, :launcher_identity, :arguments, :diagnostic
  ) do
    def initialize(capability:, supported:, provider:, launcher_identity:,
                   arguments: [], diagnostic: nil)
      super(
        capability: capability.to_sym,
        supported: supported == true,
        provider: provider.to_sym,
        launcher_identity: Immutable.string(launcher_identity),
        arguments: Immutable.strings(arguments),
        diagnostic: diagnostic.nil? ? nil : Immutable.string(diagnostic)
      )
    end
  end

  IdentityArguments = Data.define(
    :model, :requested_effort, :effective_effort, :effort_supported,
    :model_pinned, :native_arguments
  ) do
    def initialize(model:, requested_effort:, effective_effort:, effort_supported:,
                   model_pinned:, native_arguments:)
      super(
        model: Immutable.string(model),
        requested_effort:
          requested_effort.nil? ? nil : Immutable.string(requested_effort),
        effective_effort:
          effective_effort.nil? ? nil : Immutable.string(effective_effort),
        effort_supported: effort_supported == true,
        model_pinned: model_pinned == true,
        native_arguments: Immutable.strings(native_arguments)
      )
    end
  end

  Request = Data.define(
    :profile, :prompt, :permission_mode, :permission_arguments,
    :add_dirs, :require_add_dirs,
    :allowed_tools, :disallowed_tools, :max_budget_usd,
    :model, :effort, :pin_model, :identity_arguments,
    :capabilities, :raw_cli_arguments, :trusted_cli_arguments,
    :executable, :command_prefix, :include_output_format
  ) do
    def initialize(profile:, prompt:, permission_mode: nil, permission_arguments: nil,
                   add_dirs: [], require_add_dirs: false, allowed_tools: nil,
                   disallowed_tools: nil, max_budget_usd: nil, model: nil,
                   effort: nil, pin_model: true, identity_arguments: [],
                   capabilities: [], raw_cli_arguments: [],
                   trusted_cli_arguments: [], executable: nil,
                   command_prefix: [], include_output_format: true)
      super(
        profile: profile,
        prompt: Immutable.string(prompt),
        permission_mode:
          permission_mode.nil? ? nil : Immutable.string(permission_mode),
        permission_arguments:
          permission_arguments.nil? ? nil : Immutable.strings(permission_arguments),
        add_dirs: Immutable.strings(add_dirs),
        require_add_dirs: require_add_dirs == true,
        allowed_tools: Immutable.strings(allowed_tools),
        disallowed_tools: Immutable.strings(disallowed_tools),
        max_budget_usd: max_budget_usd,
        model: model.nil? ? nil : Immutable.string(model),
        effort: effort.nil? ? nil : Immutable.string(effort),
        pin_model: pin_model != false,
        identity_arguments: Immutable.strings(identity_arguments),
        capabilities: Immutable.symbols(capabilities),
        raw_cli_arguments: Immutable.strings(raw_cli_arguments),
        trusted_cli_arguments: Immutable.strings(trusted_cli_arguments),
        executable: executable.nil? ? nil : Immutable.string(executable),
        command_prefix: Immutable.strings(command_prefix),
        include_output_format: include_output_format != false
      )
    end
  end

  CompiledInvocation = Data.define(
    :argv, :stdin_data, :provider, :launcher_identity, :capability_evidence
  ) do
    def initialize(argv:, stdin_data:, provider:, launcher_identity:,
                   capability_evidence:)
      super(
        argv: Immutable.strings(argv),
        stdin_data: stdin_data.nil? ? nil : Immutable.string(stdin_data),
        provider: provider.to_sym,
        launcher_identity: Immutable.string(launcher_identity),
        capability_evidence: Array(capability_evidence).freeze
      )
    end
  end

  AuthConfiguration = Data.define(:status, :source, :diagnostic) do
    STATUSES = %i[configured missing not_checked].freeze

    def initialize(status:, source: nil, diagnostic: nil)
      normalized_status = status.to_sym
      unless STATUSES.include?(normalized_status)
        raise ArgumentError,
              "unknown auth configuration status #{status.inspect}; valid: #{STATUSES.inspect}"
      end

      super(
        status: normalized_status,
        source: source.nil? ? nil : Immutable.string(source),
        diagnostic: diagnostic.nil? ? nil : Immutable.string(diagnostic)
      )
    end

    def configured?
      status == :configured
    end
  end

  ProbeResult = Data.define(
    :provider, :ready, :installed, :executable, :version, :minimum_version,
    :auth_configuration, :capability_evidence, :diagnostic
  ) do
    def initialize(provider:, ready:, installed:, executable:, version:,
                   minimum_version:, auth_configuration:, capability_evidence:,
                   diagnostic:)
      super(
        provider: provider.to_sym,
        ready: ready == true,
        installed: installed == true,
        executable: Immutable.string(executable),
        version: version.nil? ? nil : Immutable.string(version),
        minimum_version:
          minimum_version.nil? ? nil : Immutable.string(minimum_version),
        auth_configuration: auth_configuration,
        capability_evidence: Array(capability_evidence).freeze,
        diagnostic: diagnostic.nil? ? nil : Immutable.string(diagnostic)
      )
    end
  end

  ObservableResult = Data.define(
    :provider, :launcher_identity, :exit_code, :timed_out, :status,
    :usage, :final_message, :diagnostic, :provider_signal
  ) do
    def initialize(provider:, launcher_identity:, exit_code:, timed_out:,
                   status:, usage:, final_message:, diagnostic:,
                   provider_signal: nil)
      super(
        provider: provider.to_sym,
        launcher_identity: Immutable.string(launcher_identity),
        exit_code: exit_code,
        timed_out: timed_out == true,
        status: status&.to_sym,
        usage: usage&.dup&.freeze,
        final_message:
          final_message.nil? ? nil : Immutable.string(final_message),
        diagnostic: diagnostic.nil? ? nil : Immutable.string(diagnostic),
        provider_signal: provider_signal&.dup&.freeze
      )
    end
  end


  Route = Data.define(:provider, :model) do
    ROUTE_PATTERN = /\A(?<provider>[a-zA-Z0-9][a-zA-Z0-9._-]*)\/(?<model>[^\s\/][^\s]*)\z/

    def initialize(provider:, model:)
      normalized_provider = Immutable.string(provider)
      normalized_model = Immutable.string(model)
      route = "#{normalized_provider}/#{normalized_model}"
      unless ROUTE_PATTERN.match?(route) && !normalized_model.include?("\0")
        raise ArgumentError,
              "OpenCode route must be a full provider/model value"
      end

      super(provider: normalized_provider, model: normalized_model)
    end

    def self.parse(value)
      match = ROUTE_PATTERN.match(value.to_s)
      unless match
        raise ArgumentError,
              "OpenCode route must be a full provider/model value"
      end

      new(provider: match[:provider], model: match[:model])
    end

    def to_s
      "#{provider}/#{model}"
    end
  end

  OpenCodePermissionPolicy = Data.define(:rules) do
    ACTIONS = %w[allow ask deny].freeze

    def initialize(rules = nil, **keywords)
      value = rules || keywords[:rules] || keywords
      normalized = Immutable.hash(value || {})
      raise ArgumentError, "OpenCode permission policy cannot be empty" if normalized.empty?

      validate_actions!(normalized)
      super(rules: normalized)
    end

    private

    def validate_actions!(value)
      value.each_value do |entry|
        if entry.is_a?(Hash)
          validate_actions!(entry)
        elsif !ACTIONS.include?(entry)
          raise ArgumentError,
                "OpenCode permission action must be allow, ask, or deny"
        end
      end
    end
  end

  OpenCodePreparationRequest = Data.define(
    :request, :working_directory, :invocation_root,
    :configuration_path, :configuration,
    :credential_environment_keys, :credential_file,
    :permission_policy, :additional_read_roots,
    :additional_write_roots, :plugins, :pure
  ) do
    def initialize(request:, working_directory:, invocation_root:,
                   configuration_path: nil, configuration: nil,
                   credential_environment_keys: [], credential_file: nil,
                   permission_policy: nil, additional_read_roots: [],
                   additional_write_roots: [], plugins: [], pure: true)
      unless request.is_a?(Request)
        raise ArgumentError, "request must be an AgentCliRuntime::Request"
      end
      if configuration_path && configuration
        raise ArgumentError,
              "choose configuration_path or configuration, not both"
      end
      if permission_policy &&
         !permission_policy.is_a?(OpenCodePermissionPolicy)
        raise ArgumentError,
              "permission_policy must be an OpenCodePermissionPolicy"
      end

      keys = Immutable.strings(credential_environment_keys)
      invalid = keys.find { |key| !key.match?(/\A[A-Z][A-Z0-9_]*\z/) }
      raise ArgumentError, "invalid credential environment key" if invalid
      raise ArgumentError, "credential environment keys must be unique" if keys.uniq.length != keys.length

      super(
        request: request,
        working_directory: Immutable.string(working_directory),
        invocation_root: Immutable.string(invocation_root),
        configuration_path:
          configuration_path.nil? ? nil : Immutable.string(configuration_path),
        configuration:
          configuration.nil? ? nil : Immutable.hash(configuration),
        credential_environment_keys: keys,
        credential_file:
          credential_file.nil? ? nil : Immutable.string(credential_file),
        permission_policy: permission_policy,
        additional_read_roots: Immutable.strings(additional_read_roots),
        additional_write_roots: Immutable.strings(additional_write_roots),
        plugins: Immutable.strings(plugins),
        pure: pure != false
      )
    end
  end

  ProbeRequest = Data.define(
    :profile, :route, :variant, :environment,
    :credential_environment_keys, :credential_file_staged
  ) do
    def initialize(profile:, route:, variant: nil, environment: {},
                   credential_environment_keys: [],
                   credential_file_staged: false)
      parsed_route = route.is_a?(Route) ? route : Route.parse(route)
      super(
        profile: profile,
        route: parsed_route,
        variant: variant.nil? ? nil : Immutable.string(variant),
        environment: Immutable.hash(environment),
        credential_environment_keys:
          Immutable.strings(credential_environment_keys),
        credential_file_staged: credential_file_staged == true
      )
    end
  end

  RouteProbeResult = Data.define(
    :provider, :ready, :installed, :executable, :version,
    :minimum_version, :auth_configuration, :route,
    :route_available, :available_variants,
    :capability_evidence, :diagnostic
  ) do
    def initialize(provider:, ready:, installed:, executable:, version:,
                   minimum_version:, auth_configuration:, route:,
                   route_available:, available_variants:,
                   capability_evidence:, diagnostic: nil)
      super(
        provider: provider.to_sym,
        ready: ready == true,
        installed: installed == true,
        executable: Immutable.string(executable),
        version: version.nil? ? nil : Immutable.string(version),
        minimum_version:
          minimum_version.nil? ? nil : Immutable.string(minimum_version),
        auth_configuration: auth_configuration,
        route: route,
        route_available: route_available == true,
        available_variants: Immutable.strings(available_variants),
        capability_evidence: Array(capability_evidence).freeze,
        diagnostic:
          diagnostic.nil? ? nil : Immutable.string(diagnostic)
      )
    end
  end

  class PreparedInvocation
    attr_reader :invocation, :environment, :credential_environment_keys,
                :invocation_root, :generated_paths, :configuration_path,
                :requested_route, :configuration_source, :probe_result

    def initialize(invocation:, environment:, credential_environment_keys:,
                   invocation_root:, generated_paths:, configuration_path:,
                   requested_route:, configuration_source:, probe_result:,
                   cleanup:)
      @invocation = invocation
      @environment = Immutable.hash(environment)
      @credential_environment_keys =
        Immutable.strings(credential_environment_keys)
      @invocation_root = Immutable.string(invocation_root)
      @generated_paths = Immutable.strings(generated_paths)
      @configuration_path = Immutable.string(configuration_path)
      @requested_route = requested_route
      @configuration_source =
        configuration_source.nil? ? nil : Immutable.string(configuration_source)
      @probe_result = probe_result
      @cleanup = cleanup
      freeze
    end

    def environment_for(env: ENV)
      selected = credential_environment_keys.each_with_object({}) do |key, values|
        value = env[key]
        values[key] = value.to_s unless value.to_s.empty?
      end
      environment.merge(selected).freeze
    end

    def cleanup!
      @cleanup.call
      nil
    end
  end
end
