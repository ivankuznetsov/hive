require "agent_cli_runtime"
require "hive/agent_profiles"

module Hive
  # Stable Hive compatibility facade over the published agent-cli-runtime gem.
  # Hive adds only workflow policy that the provider-neutral package must not
  # own: admitted model routing and named subscription/session bindings.
  module AgentRuntime
    DIAGNOSTIC_BYTES = AgentCliRuntime::DIAGNOSTIC_BYTES

    module Immutable
      module_function

      def string(value)
        string = value.to_s
        string.frozen? ? string : string.dup.freeze
      end

      def values(values)
        Array(values).map { |value| string(value) }.freeze
      end
    end
    private_constant :Immutable

    CapabilityEvidence = AgentCliRuntime::CapabilityEvidence
    CompiledInvocation = AgentCliRuntime::CompiledInvocation
    ObservableResult = AgentCliRuntime::ObservableResult

    Request = Data.define(
      :profile, :prompt, :permission_mode, :permission_arguments,
      :add_dirs, :require_add_dirs, :allowed_tools, :disallowed_tools,
      :max_budget_usd, :model, :effort, :pin_model, :identity_arguments,
      :routing_arguments, :capabilities, :raw_cli_arguments,
      :trusted_cli_arguments, :executable, :command_prefix,
      :include_output_format
    ) do
      def initialize(profile:, prompt:, permission_mode: nil,
                     permission_arguments: nil, add_dirs: [],
                     require_add_dirs: false, allowed_tools: nil,
                     disallowed_tools: nil, max_budget_usd: nil,
                     model: nil, effort: nil, pin_model: true,
                     identity_arguments: [], routing_arguments: nil,
                     capabilities: [], raw_cli_arguments: [],
                     trusted_cli_arguments: [], executable: nil,
                     command_prefix: [], include_output_format: true)
        super(
          profile: profile,
          prompt: Immutable.string(prompt),
          permission_mode:
            permission_mode.nil? ? nil : Immutable.string(permission_mode),
          permission_arguments:
            permission_arguments.nil? ? nil : Immutable.values(permission_arguments),
          add_dirs: Immutable.values(add_dirs),
          require_add_dirs: require_add_dirs == true,
          allowed_tools: Immutable.values(allowed_tools),
          disallowed_tools: Immutable.values(disallowed_tools),
          max_budget_usd: max_budget_usd,
          model: model.nil? ? nil : Immutable.string(model),
          effort: effort.nil? ? nil : Immutable.string(effort),
          pin_model: pin_model != false,
          identity_arguments: Immutable.values(identity_arguments),
          routing_arguments: routing_arguments,
          capabilities: Array(capabilities).map(&:to_sym).uniq.freeze,
          raw_cli_arguments: Immutable.values(raw_cli_arguments),
          trusted_cli_arguments: Immutable.values(trusted_cli_arguments),
          executable: executable.nil? ? nil : Immutable.string(executable),
          command_prefix: Immutable.values(command_prefix),
          include_output_format: include_output_format != false
        )
      end
    end

    # Preserve Hive's smaller historic probe value while the package owns the
    # richer local diagnostic contract exposed by AgentCliRuntime::ProbeResult.
    ProbeResult = Data.define(
      :provider, :launcher_identity, :version, :capability_evidence
    ) do
      def initialize(provider:, launcher_identity:, version:,
                     capability_evidence:)
        super(
          provider: provider.to_sym,
          launcher_identity: Immutable.string(launcher_identity),
          version: version.nil? ? nil : Immutable.string(version),
          capability_evidence: Array(capability_evidence).freeze
        )
      end
    end

    class Error < Hive::AgentError
      attr_reader :evidence

      def initialize(message, evidence:)
        super(message)
        @evidence = evidence
      end
    end

    class UnsupportedCapability < Error; end
    class ProbeError < Error; end
    class CompilationError < Error; end

    module_function

    def compile(request)
      unless request.is_a?(Request)
        compilation_error!(nil, ArgumentError.new(
          "request must be a Hive::AgentRuntime::Request"
        ))
      end

      profile = request.profile
      require_headless!(profile)
      runtime = runtime_profile(profile)
      unless runtime
        compilation_error!(profile, ArgumentError.new(
          "agent profile #{profile_name(profile).inspect} has no agent-cli-runtime profile"
        ))
      end

      routing = routing_arguments(profile, request)
      identity = legacy_identity_arguments(profile, request)
      named_evidence = request.capabilities.map do |capability|
        require_capability!(profile, capability)
      end
      named_arguments = named_evidence.flat_map(&:arguments)

      public_request = AgentCliRuntime::Request.new(
        profile: runtime,
        prompt: request.prompt,
        permission_mode: request.permission_mode,
        permission_arguments: request.permission_arguments,
        add_dirs: request.add_dirs,
        require_add_dirs: request.require_add_dirs,
        allowed_tools: supported_tool_scope(profile, :allowed, request.allowed_tools),
        disallowed_tools:
          supported_tool_scope(profile, :disallowed, request.disallowed_tools),
        max_budget_usd:
          profile.respond_to?(:budget_flag) && profile.budget_flag ?
            request.max_budget_usd : nil,
        identity_arguments:
          identity.fetch(:arguments) + routing.fetch(:subcommand) +
          named_arguments,
        raw_cli_arguments: request.raw_cli_arguments,
        trusted_cli_arguments: request.trusted_cli_arguments,
        executable: request.executable,
        command_prefix: request.command_prefix,
        include_output_format: request.include_output_format
      )

      invocation = AgentCliRuntime.compile(public_request)
      argv = invocation.argv.dup
      unless routing.fetch(:global).empty?
        argv.insert(request.command_prefix.length + 1, *routing.fetch(:global))
      end
      CompiledInvocation.new(
        argv: argv,
        stdin_data: invocation.stdin_data,
        provider: invocation.provider,
        launcher_identity: invocation.launcher_identity,
        capability_evidence:
          invocation.capability_evidence + identity.fetch(:evidence) +
          routing.fetch(:evidence) + named_evidence
      )
    rescue Error
      raise
    rescue AgentCliRuntime::UnsupportedCapability => e
      raise_runtime_error!(UnsupportedCapability, profile, e)
    rescue AgentCliRuntime::Error => e
      compilation_error!(profile, e)
    rescue StandardError => e
      compilation_error!(profile, e)
    end

    def prepare!(profile, launch_binding: nil)
      public_profile = runtime_profile(profile)
      version = nil
      if public_profile
        Hive::AgentProfiles::LaunchBindings.with_preflight_environment(
          launch_binding
        ) do
          version =
            if profile.respond_to?(:check_version!)
              profile.check_version!
            else
              public_profile.check_version!(env: ENV)
            end
          require_auth_configuration!(public_profile) if
            profile.respond_to?(:auth_configuration_required?) &&
            profile.auth_configuration_required?
          profile.preflight! if profile.respond_to?(:preflight!)
        end
      else
        version = profile.check_version!
        Hive::AgentProfiles::LaunchBindings.with_preflight_environment(
          launch_binding
        ) { profile.preflight! }
      end

      ProbeResult.new(
        provider: profile_name(profile),
        launcher_identity: launcher_identity(profile),
        version: version,
        capability_evidence: [
          supported_evidence(profile, :headless),
          supported_evidence(profile, :version, [ version ]),
          supported_evidence(profile, :preflight)
        ]
      )
    rescue Error
      raise
    rescue AgentCliRuntime::Error => e
      raise_runtime_error!(ProbeError, profile, e, capability: :probe)
    rescue StandardError => e
      raise_runtime_error!(ProbeError, profile, e, capability: :probe)
    end

    def require_capability!(profile, capability)
      arguments = profile.require_cli_capability!(capability)
      supported_evidence(profile, capability, arguments)
    rescue Error
      raise
    rescue AgentCliRuntime::Error, StandardError => e
      raise_runtime_error!(
        UnsupportedCapability, profile, e, capability: capability
      )
    end

    def extract_usage(profile, event)
      public_profile = runtime_profile(profile)
      if public_profile
        AgentCliRuntime.extract_usage(public_profile, event)
      else
        normalize_usage(profile.extract_usage_event(event))
      end
    rescue StandardError
      nil
    end

    def observe(profile, result)
      public_profile = runtime_profile(profile)
      return AgentCliRuntime.observe(public_profile, result) if public_profile

      raw = result.is_a?(Hash) ? result : {}
      ObservableResult.new(
        provider: profile_name(profile),
        launcher_identity: launcher_identity(profile),
        exit_code: raw[:exit_code],
        timed_out: raw[:timed_out],
        status: raw[:status],
        usage: normalize_usage(raw[:usage]),
        final_message: raw[:final_message],
        diagnostic: safe_diagnostic(raw[:error_message] || raw[:limit_text]),
        provider_signal: raw[:provider_signal]
      )
    end

    def runtime_profile(profile)
      return profile if profile.is_a?(AgentCliRuntime::Profile)
      return profile.runtime_profile if profile.respond_to?(:runtime_profile)

      nil
    end
    private_class_method :runtime_profile

    def require_auth_configuration!(profile)
      environment = ENV.to_h
      if profile.name == :grok
        # Hive binds CLI subscription/session state. API-key support remains a
        # package compatibility feature for independent consumers.
        environment.delete("XAI_API_KEY")
        environment.delete("GROK_CODE_XAI_API_KEY")
      end
      auth = profile.auth_configuration(env: environment)
      return if auth.configured?

      evidence = AgentCliRuntime::CapabilityEvidence.new(
        capability: :auth_configuration,
        supported: false,
        provider: profile.name,
        launcher_identity: profile.launcher_identity,
        diagnostic: auth.diagnostic ||
          "local subscription/session configuration is missing"
      )
      raise AgentCliRuntime::ProbeError.new(
        evidence.diagnostic, evidence: evidence
      )
    end
    private_class_method :require_auth_configuration!

    def require_headless!(profile)
      supported =
        !profile.respond_to?(:headless_supported) || profile.headless_supported
      return if supported

      evidence = unsupported_evidence(
        profile, :headless,
        "agent profile #{profile_name(profile).inspect} is not headless-supported"
      )
      raise UnsupportedCapability.new(evidence.diagnostic, evidence: evidence)
    end
    private_class_method :require_headless!

    def legacy_identity_arguments(profile, request)
      evidence = []
      arguments = request.identity_arguments.dup
      return { arguments:, evidence: } unless request.model || request.effort
      unless request.model
        package_unsupported!(
          profile, :effort,
          "effort requires an explicit model in an invocation request"
        )
      end
      if request.pin_model &&
         (!profile.respond_to?(:model_argument_builder) ||
          !profile.model_argument_builder)
        package_unsupported!(
          profile, :model,
          "agent profile #{profile_name(profile).inspect} cannot pin a model"
        )
      end
      if request.effort &&
         (!profile.respond_to?(:effort_argument_builder) ||
          !profile.effort_argument_builder)
        package_unsupported!(
          profile, :effort,
          "agent profile #{profile_name(profile).inspect} cannot set reasoning effort"
        )
      end

      identity = profile.identity_arguments(
        model: request.model, effort: request.effort,
        pin_model: request.pin_model
      )
      arguments.concat(identity.native_arguments)
      evidence << supported_evidence(
        profile, :model, identity.native_arguments
      )
      evidence << supported_evidence(profile, :effort) if request.effort
      { arguments:, evidence: }
    end
    private_class_method :legacy_identity_arguments

    def package_unsupported!(profile, capability, diagnostic)
      evidence = unsupported_evidence(profile, capability, diagnostic)
      raise AgentCliRuntime::UnsupportedCapability.new(
        evidence.diagnostic, evidence: evidence
      )
    end
    private_class_method :package_unsupported!

    def routing_arguments(profile, request)
      empty = { global: [], subcommand: [], evidence: [] }
      return empty unless request.routing_arguments
      if !request.identity_arguments.empty? || request.model || request.effort
        raise ArgumentError,
              "routing_arguments cannot be combined with legacy identity " \
              "model/effort arguments"
      end
      unless profile.respond_to?(:validate_routing_arguments!)
        evidence = unsupported_evidence(
          profile, :model_routing,
          "agent profile #{profile_name(profile).inspect} does not support model routing"
        )
        raise UnsupportedCapability.new(evidence.diagnostic, evidence: evidence)
      end

      arguments = profile.validate_routing_arguments!(request.routing_arguments)
      {
        global: arguments.global_arguments,
        subcommand: arguments.subcommand_arguments,
        evidence: [
          supported_evidence(profile, :model_routing, arguments.native_arguments)
        ]
      }
    end
    private_class_method :routing_arguments

    def supported_tool_scope(profile, scope, tools)
      return nil if Array(tools).empty?
      flags = profile.respond_to?(:tool_scope_flags) ? profile.tool_scope_flags : {}

      flags.key?(scope) ? tools : nil
    end
    private_class_method :supported_tool_scope

    def supported_evidence(profile, capability, arguments = [])
      CapabilityEvidence.new(
        capability: capability,
        supported: true,
        provider: profile_name(profile),
        launcher_identity: launcher_identity(profile),
        arguments: arguments
      )
    end
    private_class_method :supported_evidence

    def unsupported_evidence(profile, capability, diagnostic)
      CapabilityEvidence.new(
        capability: capability,
        supported: false,
        provider: profile_name(profile),
        launcher_identity: launcher_identity(profile),
        diagnostic: safe_diagnostic(diagnostic)
      )
    end
    private_class_method :unsupported_evidence

    def raise_runtime_error!(error_class, profile, error, capability: nil)
      package_evidence = error.respond_to?(:evidence) ? error.evidence : nil
      effective_capability =
        capability || package_evidence&.capability || :compilation
      evidence = unsupported_evidence(
        profile, effective_capability,
        package_evidence&.diagnostic || error
      )
      message =
        if error_class == ProbeError
          "agent profile #{profile_name(profile).inspect} probe failed: #{evidence.diagnostic}"
        elsif error_class == UnsupportedCapability
          "agent profile #{profile_name(profile).inspect} cannot provide " \
            "#{effective_capability.to_sym.inspect}: #{evidence.diagnostic}"
        else
          "agent invocation compilation failed: #{evidence.diagnostic}"
        end
      raise error_class.new(message, evidence: evidence), cause: error
    end
    private_class_method :raise_runtime_error!

    def compilation_error!(profile, error)
      raise_runtime_error!(
        CompilationError, profile, error, capability: :compilation
      )
    end
    private_class_method :compilation_error!

    def normalize_usage(usage)
      return nil unless usage.is_a?(Hash)

      input = usage.key?(:input) ? usage[:input] : usage["input"]
      output = usage.key?(:output) ? usage[:output] : usage["output"]
      cached = usage.key?(:cached) ? usage[:cached] : usage["cached"]
      model = usage.key?(:model) ? usage[:model] : usage["model"]
      {
        input: [ input.to_i, 0 ].max,
        output: [ output.to_i, 0 ].max,
        cached: [ cached.to_i, 0 ].max,
        model: model&.to_s&.dup&.freeze
      }.freeze
    end
    private_class_method :normalize_usage

    def safe_diagnostic(value)
      AgentCliRuntime::Redactor.diagnostic(value)
    end
    private_class_method :safe_diagnostic

    def profile_name(profile)
      profile&.respond_to?(:name) ? profile.name : :unknown
    end
    private_class_method :profile_name

    def launcher_identity(profile)
      if profile&.respond_to?(:launcher_identity) && profile.launcher_identity
        profile.launcher_identity
      else
        "AgentProfile/v1:#{profile_name(profile)}"
      end
    end
    private_class_method :launcher_identity
  end
end
