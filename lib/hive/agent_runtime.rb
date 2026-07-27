require "hive/agent_profiles"
require "hive/permission_scope"
require "hive/secret_patterns"

module Hive
  # Provider-neutral contract between Hive orchestration and an AgentProfile.
  #
  # This component compiles one immutable request into argv/stdin and
  # normalizes provider observations. It deliberately does not spawn
  # processes, enforce workflow timeouts, accept artifacts, retry work, or
  # decide whether a stage succeeded; those remain Hive policy.
  module AgentRuntime
    DIAGNOSTIC_BYTES = 512

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
          arguments: Immutable.values(arguments),
          diagnostic: diagnostic.nil? ? nil : Immutable.string(diagnostic)
        )
      end
    end

    Request = Data.define(
      :profile, :prompt, :permission_mode, :permission_arguments,
      :add_dirs, :require_add_dirs,
      :allowed_tools, :disallowed_tools, :max_budget_usd,
      :model, :effort, :pin_model, :identity_arguments,
      :routing_arguments,
      :capabilities, :raw_cli_arguments, :trusted_cli_arguments,
      :executable, :command_prefix, :include_output_format
    ) do
      def initialize(profile:, prompt:, permission_mode: nil, permission_arguments: nil, add_dirs: [],
                     require_add_dirs: false, allowed_tools: nil,
                     disallowed_tools: nil, max_budget_usd: nil,
                     model: nil, effort: nil, pin_model: true,
                     identity_arguments: [], routing_arguments: nil,
                     capabilities: [],
                     raw_cli_arguments: [], trusted_cli_arguments: [],
                     executable: nil, command_prefix: [],
                     include_output_format: true)
        super(
          profile: profile,
          prompt: Immutable.string(prompt),
          permission_mode: permission_mode.nil? ? nil : Immutable.string(permission_mode),
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

    CompiledInvocation = Data.define(
      :argv, :stdin_data, :provider, :launcher_identity, :capability_evidence
    ) do
      def initialize(argv:, stdin_data:, provider:, launcher_identity:, capability_evidence:)
        super(
          argv: Immutable.values(argv),
          stdin_data: stdin_data.nil? ? nil : Immutable.string(stdin_data),
          provider: provider.to_sym,
          launcher_identity: Immutable.string(launcher_identity),
          capability_evidence: Array(capability_evidence).freeze
        )
      end
    end

    ProbeResult = Data.define(
      :provider, :launcher_identity, :version, :capability_evidence
    ) do
      def initialize(provider:, launcher_identity:, version:, capability_evidence:)
        super(
          provider: provider.to_sym,
          launcher_identity: Immutable.string(launcher_identity),
          version: version.nil? ? nil : Immutable.string(version),
          capability_evidence: Array(capability_evidence).freeze
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
          final_message: final_message.nil? ? nil : Immutable.string(final_message),
          diagnostic: diagnostic.nil? ? nil : Immutable.string(diagnostic)
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
        raise ArgumentError, "request must be a Hive::AgentRuntime::Request"
      end

      profile = request.profile
      evidence = []
      require_headless!(profile, evidence)
      routing = routing_arguments(profile, request, evidence)

      argv = [ request.executable || profile.bin ]
      argv.concat(routing.fetch(:global))
      prompt_style = profile_prompt_style(profile)
      if profile.headless_flag
        argv << profile.headless_flag
        argv << request.prompt if prompt_style == :headless_flag_value
      end

      argv.concat(
        permission_arguments(
          profile, request.permission_mode, evidence,
          trusted_arguments: request.permission_arguments
        )
      )
      argv.concat(directory_arguments(profile, request, evidence))
      argv.concat(tool_scope_arguments(profile, request))
      argv.concat(budget_arguments(profile, request.max_budget_usd))
      argv.concat(identity_arguments(profile, request, evidence))
      argv.concat(routing.fetch(:subcommand))

      request.capabilities.each do |capability|
        capability_evidence = require_capability!(profile, capability)
        evidence << capability_evidence
        argv.concat(capability_evidence.arguments)
      end

      unless request.raw_cli_arguments.empty?
        unless raw_cli_arguments_supported?(profile)
          unsupported!(
            profile, :raw_cli_arguments,
            "agent profile #{profile_name(profile).inspect} does not accept raw CLI arguments",
            evidence
          )
        end
        evidence << supported_evidence(profile, :raw_cli_arguments, request.raw_cli_arguments)
        argv.concat(request.raw_cli_arguments)
      end
      argv.concat(request.trusted_cli_arguments)

      if request.include_output_format && profile.respond_to?(:output_format_flags)
        argv.concat(Array(profile.output_format_flags))
      end
      argv << (prompt_style == :stdin ? "-" : request.prompt) unless prompt_style == :headless_flag_value

      CompiledInvocation.new(
        argv: request.command_prefix + argv,
        stdin_data: prompt_style == :stdin ? request.prompt : nil,
        provider: profile_name(profile),
        launcher_identity: launcher_identity(profile),
        capability_evidence: evidence
      )
    rescue Error
      raise
    rescue StandardError => e
      profile = request.profile if request.is_a?(Request)
      compilation_error!(profile, :compilation, e)
    end

    def prepare!(profile)
      version = profile.check_version!
      profile.preflight!
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
    rescue StandardError => e
      evidence = unsupported_evidence(profile, :probe, safe_diagnostic(e))
      raise ProbeError.new(
        "agent profile #{profile_name(profile).inspect} probe failed: #{evidence.diagnostic}",
        evidence: evidence
      ), cause: e
    end

    def require_capability!(profile, capability)
      arguments = profile.require_cli_capability!(capability)
      supported_evidence(profile, capability, arguments)
    rescue Error
      raise
    rescue StandardError => e
      evidence = unsupported_evidence(profile, capability, safe_diagnostic(e))
      raise UnsupportedCapability.new(
        "agent profile #{profile_name(profile).inspect} cannot provide " \
        "#{capability.to_sym.inspect}: #{evidence.diagnostic}",
        evidence: evidence
      ), cause: e
    end

    def extract_usage(profile, event)
      usage = profile.extract_usage_event(event)
      normalize_usage(usage)
    rescue StandardError
      nil
    end

    def observe(profile, result)
      raw = result.is_a?(Hash) ? result : {}
      ObservableResult.new(
        provider: profile_name(profile),
        launcher_identity: launcher_identity(profile),
        exit_code: raw[:exit_code],
        timed_out: raw[:timed_out],
        status: raw[:status],
        usage: normalize_usage(raw[:usage]),
        final_message: raw[:final_message],
        diagnostic: safe_diagnostic(raw[:error_message] || raw[:limit_text])
      )
    end

    def require_headless!(profile, evidence)
      supported = !profile.respond_to?(:headless_supported) || profile.headless_supported
      return evidence << supported_evidence(profile, :headless) if supported

      unsupported!(
        profile, :headless,
        "agent profile #{profile_name(profile).inspect} is not headless-supported",
        evidence
      )
    end
    private_class_method :require_headless!

    def permission_arguments(profile, permission_mode, evidence, trusted_arguments: nil)
      arguments =
        if trusted_arguments
          trusted_arguments
        elsif profile.respond_to?(:permission_flags)
          profile.permission_flags(permission_mode)
        elsif profile.respond_to?(:permission_skip_flag) && profile.permission_skip_flag
          [ profile.permission_skip_flag ]
        else
          []
        end
      capability = permission_mode&.tr("-", "_")&.to_sym || :permission_bypass
      evidence << supported_evidence(profile, capability, arguments)
      arguments
    rescue ArgumentError => e
      capability = permission_mode&.tr("-", "_")&.to_sym || :permission
      unsupported!(profile, capability, e.message, evidence)
    end
    private_class_method :permission_arguments

    def directory_arguments(profile, request, evidence)
      return [] if request.add_dirs.empty?

      flag = profile.respond_to?(:add_dir_flag) ? profile.add_dir_flag : nil
      unless flag
        if request.require_add_dirs
          unsupported!(
            profile, :add_directory,
            "agent profile #{profile_name(profile).inspect} cannot constrain additional directories",
            evidence
          )
        end
        evidence << unsupported_evidence(
          profile, :add_directory,
          "unsupported; directories intentionally omitted"
        )
        return []
      end

      arguments = request.add_dirs.flat_map { |directory| [ flag, directory ] }
      evidence << supported_evidence(profile, :add_directory, arguments)
      arguments
    end
    private_class_method :directory_arguments

    def tool_scope_arguments(profile, request)
      flags = profile.respond_to?(:tool_scope_flags) ? profile.tool_scope_flags : {}
      arguments = []
      if (value = Hive::PermissionScope.tool_csv(request.allowed_tools)) && flags[:allowed]
        arguments.concat([ flags[:allowed], value ])
      end
      if (value = Hive::PermissionScope.tool_csv(request.disallowed_tools)) && flags[:disallowed]
        arguments.concat([ flags[:disallowed], value ])
      end
      arguments
    end
    private_class_method :tool_scope_arguments

    def budget_arguments(profile, max_budget_usd)
      flag = profile.respond_to?(:budget_flag) ? profile.budget_flag : nil
      flag && max_budget_usd ? [ flag, max_budget_usd.to_s ] : []
    end
    private_class_method :budget_arguments

    def identity_arguments(profile, request, evidence)
      arguments = request.identity_arguments.dup
      return arguments unless request.model || request.effort

      unless request.model
        unsupported!(
          profile, :effort, "effort requires an explicit model in an invocation request", evidence
        )
      end
      if request.pin_model &&
         (!profile.respond_to?(:model_argument_builder) || !profile.model_argument_builder)
        unsupported!(
          profile, :model,
          "agent profile #{profile_name(profile).inspect} cannot pin a model",
          evidence
        )
      end
      if request.effort &&
         (!profile.respond_to?(:effort_argument_builder) || !profile.effort_argument_builder)
        unsupported!(
          profile, :effort,
          "agent profile #{profile_name(profile).inspect} cannot set reasoning effort",
          evidence
        )
      end

      identity = profile.identity_arguments(
        model: request.model, effort: request.effort, pin_model: request.pin_model
      )
      evidence << supported_evidence(profile, :model, identity.native_arguments)
      evidence << supported_evidence(profile, :effort) if request.effort
      arguments.concat(identity.native_arguments)
    end
    private_class_method :identity_arguments

    def routing_arguments(profile, request, evidence)
      return { global: [], subcommand: [] } unless request.routing_arguments
      unless profile.respond_to?(:validate_routing_arguments!)
        unsupported!(
          profile, :model_routing,
          "agent profile #{profile_name(profile).inspect} does not support model routing",
          evidence
        )
      end

      arguments = profile.validate_routing_arguments!(request.routing_arguments)
      native_arguments = arguments.native_arguments
      evidence << supported_evidence(profile, :model_routing, native_arguments)
      {
        global: arguments.global_arguments,
        subcommand: arguments.subcommand_arguments
      }
    end
    private_class_method :routing_arguments

    def profile_prompt_style(profile)
      profile.respond_to?(:prompt_style) && profile.prompt_style ? profile.prompt_style : :positional
    end
    private_class_method :profile_prompt_style

    def raw_cli_arguments_supported?(profile)
      profile.respond_to?(:raw_cli_arguments_supported?) && profile.raw_cli_arguments_supported?
    end
    private_class_method :raw_cli_arguments_supported?

    def launcher_identity(profile)
      if profile.respond_to?(:launcher_identity) && profile.launcher_identity
        profile.launcher_identity
      else
        "AgentProfile/v1:#{profile_name(profile)}"
      end
    end
    private_class_method :launcher_identity

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
        launcher_identity: profile ? launcher_identity(profile) : "unknown",
        diagnostic: diagnostic
      )
    end
    private_class_method :unsupported_evidence

    def unsupported!(profile, capability, diagnostic, evidence)
      item = unsupported_evidence(profile, capability, safe_diagnostic(diagnostic))
      evidence << item
      raise UnsupportedCapability.new(item.diagnostic, evidence: item)
    end
    private_class_method :unsupported!

    def compilation_error!(profile, capability, error)
      evidence = unsupported_evidence(profile, capability, safe_diagnostic(error))
      raise CompilationError.new(
        "agent invocation compilation failed: #{evidence.diagnostic}",
        evidence: evidence
      ), cause: error
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
      redacted = Hive::SecretPatterns.redact(value.respond_to?(:message) ? value.message : value.to_s)
      return nil if redacted.empty?
      return redacted if redacted.bytesize <= DIAGNOSTIC_BYTES

      redacted.byteslice(0, DIAGNOSTIC_BYTES).to_s.force_encoding(Encoding::UTF_8).scrub("?")
    end
    private_class_method :safe_diagnostic

    def profile_name(profile)
      profile&.respond_to?(:name) ? profile.name : :unknown
    end
    private_class_method :profile_name
  end
end
