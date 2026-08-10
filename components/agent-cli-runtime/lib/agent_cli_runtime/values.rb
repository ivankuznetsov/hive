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
    :usage, :final_message, :diagnostic
  ) do
    def initialize(provider:, launcher_identity:, exit_code:, timed_out:,
                   status:, usage:, final_message:, diagnostic:)
      super(
        provider: provider.to_sym,
        launcher_identity: Immutable.string(launcher_identity),
        exit_code: exit_code,
        timed_out: timed_out == true,
        status: status&.to_sym,
        usage: usage&.dup&.freeze,
        final_message:
          final_message.nil? ? nil : Immutable.string(final_message),
        diagnostic: diagnostic.nil? ? nil : Immutable.string(diagnostic)
      )
    end
  end
end
