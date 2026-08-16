module AgentCliRuntime
  OPENCODE_OVERLAY_ENVIRONMENT_KEYS = %w[
    XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME TMPDIR
    OPENCODE_CONFIG OPENCODE_DISABLE_PROJECT_CONFIG
    OPENCODE_DISABLE_CLAUDE_CODE OPENCODE_DISABLE_MODELS_FETCH
    OPENCODE_DISABLE_AUTOUPDATE OPENCODE_PURE
  ].freeze

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
    :additional_write_roots, :edit_patterns, :plugins, :pure
  ) do
    def initialize(request:, working_directory:, invocation_root:,
                   configuration_path: nil, configuration: nil,
                   credential_environment_keys: [], credential_file: nil,
                   permission_policy: nil, additional_read_roots: [],
                   additional_write_roots: [], edit_patterns: [], plugins: [], pure: true)
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
      reserved = keys & OPENCODE_OVERLAY_ENVIRONMENT_KEYS
      unless reserved.empty?
        raise ArgumentError,
              "credential environment keys cannot override the OpenCode overlay: #{reserved.join(', ')}"
      end

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
        edit_patterns: Immutable.strings(edit_patterns),
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
                :requested_route, :configuration_source, :probe_result,
                :executable

    def initialize(invocation:, environment:, credential_environment_keys:,
                   invocation_root:, generated_paths:, configuration_path:,
                   requested_route:, configuration_source:, probe_result:,
                   cleanup:, executable: nil)
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
      @executable = Immutable.string(executable || invocation.argv.fetch(0))
      @cleanup = cleanup
      freeze
    end

    def environment_for(env: ENV)
      selected = credential_environment_keys.each_with_object({}) do |key, values|
        value = env[key]
        values[key] = value.to_s unless value.to_s.empty?
      end
      selected.merge(environment).freeze
    end

    def cleanup!
      @cleanup.call
      nil
    end
  end

  TerminationEvidence = Data.define(
    :exit_code, :timed_out, :cancelled, :signal
  ) do
    def initialize(exit_code:, timed_out: false, cancelled: false, signal: nil)
      unless exit_code.nil? || exit_code.is_a?(Integer)
        raise ArgumentError, "exit_code must be an Integer or nil"
      end

      super(
        exit_code: exit_code,
        timed_out: timed_out == true,
        cancelled: cancelled == true,
        signal: signal.nil? ? nil : Immutable.string(signal)
      )
    end

    def success?
      !timed_out && !cancelled && signal.nil? && exit_code == 0
    end
  end

  CapturedResult = Data.define(
    :stdout, :stderr, :termination, :inspection_output
  ) do
    def initialize(stdout:, stderr:, termination:, inspection_output: nil)
      unless termination.is_a?(TerminationEvidence)
        raise ArgumentError, "termination must be TerminationEvidence"
      end

      super(
        stdout: Immutable.string(stdout),
        stderr: Immutable.string(stderr),
        termination: termination,
        inspection_output:
          inspection_output.nil? ? nil : Immutable.string(inspection_output)
      )
    end
  end

  NormalizedUsage = Data.define(
    :input, :output, :cache_read, :cache_write, :reasoning,
    :input_includes_cache_read, :input_includes_cache_write,
    :output_includes_reasoning, :cost
  ) do
    def initialize(input: nil, output: nil, cache_read: nil, cache_write: nil,
                   reasoning: nil, input_includes_cache_read: nil,
                   input_includes_cache_write: nil,
                   output_includes_reasoning: nil,
                   provider_reported_cost: nil, cost: nil)
      if !provider_reported_cost.nil? && !cost.nil? && provider_reported_cost != cost
        raise ArgumentError, "provider_reported_cost and cost disagree"
      end
      super(
        input: number(input, :input, integer: true),
        output: number(output, :output, integer: true),
        cache_read: number(cache_read, :cache_read, integer: true),
        cache_write: number(cache_write, :cache_write, integer: true),
        reasoning: number(reasoning, :reasoning, integer: true),
        input_includes_cache_read:
          boolean(input_includes_cache_read, :input_includes_cache_read),
        input_includes_cache_write:
          boolean(input_includes_cache_write, :input_includes_cache_write),
        output_includes_reasoning:
          boolean(output_includes_reasoning, :output_includes_reasoning),
        cost: number(
          provider_reported_cost.nil? ? cost : provider_reported_cost,
          :provider_reported_cost,
          integer: false
        )
      )
    end

    def cached
      return nil if cache_read.nil? || cache_write.nil?

      cache_read + cache_write
    end

    alias provider_reported_cost cost

    private

    def number(value, label, integer:)
      return nil if value.nil?
      valid = integer ? value.is_a?(Integer) : value.is_a?(Numeric)
      valid &&= value.finite? if value.respond_to?(:finite?)
      unless valid && value >= 0
        raise ArgumentError, "#{label} must be a non-negative number or nil"
      end

      value
    end


    def boolean(value, label)
      return nil if value.nil?
      return value if value == true || value == false

      raise ArgumentError, "#{label} must be true, false, or nil"
    end
  end

  RouteIdentity = Data.define(:requested, :actual, :resolution_status) do
    RESOLUTION_STATUSES = %i[unobserved matched resolved_differently].freeze

    def initialize(requested:, actual: nil, resolution_status: nil)
      requested_route = requested.is_a?(Route) ? requested : Route.parse(requested)
      actual_route =
        if actual.nil?
          nil
        elsif actual.is_a?(Route)
          actual
        else
          Route.parse(actual)
        end
      status = resolution_status&.to_sym ||
        (actual_route.nil? ? :unobserved :
          (requested_route == actual_route ? :matched : :resolved_differently))
      unless RESOLUTION_STATUSES.include?(status)
        raise ArgumentError, "invalid route resolution status"
      end

      super(
        requested: requested_route,
        actual: actual_route,
        resolution_status: status
      )
    end
  end

  ParsedRun = Data.define(
    :session_id, :terminal_message_id, :terminal_reason,
    :final_message, :final_message_truncated, :preliminary_usage, :unknown_events
  ) do
    def initialize(session_id:, terminal_message_id:, terminal_reason:,
                   final_message:, preliminary_usage:, unknown_events: [],
                   final_message_truncated: false)
      unless preliminary_usage.is_a?(NormalizedUsage)
        raise ArgumentError, "preliminary_usage must be NormalizedUsage"
      end

      super(
        session_id: Immutable.string(session_id),
        terminal_message_id: Immutable.string(terminal_message_id),
        terminal_reason: Immutable.string(terminal_reason),
        final_message: Immutable.string(final_message),
        final_message_truncated: final_message_truncated == true,
        preliminary_usage: preliminary_usage,
        unknown_events: Immutable.strings(unknown_events)
      )
    end
  end

  InspectionCommand = Data.define(
    :argv, :stdin_data, :environment, :credential_environment_keys,
    :session_id, :message_id
  ) do
    def initialize(argv:, environment:, credential_environment_keys:,
                   session_id:, message_id:, stdin_data: nil)
      super(
        argv: Immutable.strings(argv),
        stdin_data: stdin_data.nil? ? nil : Immutable.string(stdin_data),
        environment: Immutable.hash(environment),
        credential_environment_keys:
          Immutable.strings(credential_environment_keys),
        session_id: Immutable.string(session_id),
        message_id: Immutable.string(message_id)
      )
    end

    def environment_for(env: ENV)
      selected = credential_environment_keys.each_with_object({}) do |key, values|
        value = env[key]
        values[key] = value.to_s unless value.to_s.empty?
      end
      selected.merge(environment).freeze
    end
  end

  NormalizedOutcome = Data.define(
    :provider, :launcher_identity, :kind, :termination,
    :final_message, :final_message_truncated, :identity, :usage, :diagnostic,
    :unknown_events, :session_id, :message_id
  ) do
    KINDS = %i[
      completed authentication_failure configuration_failure cli_failure
      malformed_output cancelled timed_out
    ].freeze

    def initialize(provider:, launcher_identity:, kind:, termination:,
                   final_message: nil, identity:, usage: nil, diagnostic: nil,
                   unknown_events: [], session_id: nil, message_id: nil,
                   final_message_truncated: false)
      normalized_kind = kind.to_sym
      unless KINDS.include?(normalized_kind)
        raise ArgumentError, "invalid normalized outcome kind"
      end
      unless termination.is_a?(TerminationEvidence)
        raise ArgumentError, "termination must be TerminationEvidence"
      end
      unless identity.is_a?(RouteIdentity)
        raise ArgumentError, "identity must be RouteIdentity"
      end
      unless usage.nil? || usage.is_a?(NormalizedUsage)
        raise ArgumentError, "usage must be NormalizedUsage or nil"
      end

      super(
        provider: provider.to_sym,
        launcher_identity: Immutable.string(launcher_identity),
        kind: normalized_kind,
        termination: termination,
        final_message:
          final_message.nil? ? nil : Immutable.string(final_message),
        final_message_truncated: final_message_truncated == true,
        identity: identity,
        usage: usage,
        diagnostic: diagnostic.nil? ? nil : Immutable.string(diagnostic),
        unknown_events: Immutable.strings(unknown_events),
        session_id: session_id.nil? ? nil : Immutable.string(session_id),
        message_id: message_id.nil? ? nil : Immutable.string(message_id)
      )
    end

    def completed?
      kind == :completed
    end
  end
end
