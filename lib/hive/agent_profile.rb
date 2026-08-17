require "agent_cli_runtime"
require "json"
require "hive/implementation_identity"
require "hive/model_routing"

module Hive
  # Hive policy layered over an AgentCliRuntime::Profile.
  #
  # The package owns provider compatibility: executable discovery, permission
  # flags, version/capability probes, configuration metadata, usage decoding,
  # and native model/effort arguments. Hive keeps workflow-facing policy such
  # as skills, model routing, status detection, and default-model resolution.
  class AgentProfile
    PROMPT_STYLES = AgentCliRuntime::Profile::PROMPT_STYLES
    ROUTING_ARGUMENT_PLACEMENTS = %i[global subcommand].freeze
    STRUCTURED_OUTPUT_PROTOCOLS = %i[grok_end pi_agent_end].freeze
    BILLING_SEMANTICS = %i[unknown subscription_backed api_billed].freeze
    WORKSPACE_WRITE_PERMISSION_MODE =
      AgentCliRuntime::Profile::WORKSPACE_WRITE_PERMISSION_MODE
    READ_ONLY_PERMISSION_MODE = AgentCliRuntime::Profile::READ_ONLY_PERMISSION_MODE
    VERSION_CHECK_TIMEOUT_SEC = AgentCliRuntime::Profile::CAPTURE_TIMEOUT_SECONDS
    TOOL_SCOPE_FLAGS_UNSET = Object.new.freeze
    LEGACY_CLAUDE_TOOL_SCOPE_FLAGS = {
      allowed: "--allowedTools",
      disallowed: "--disallowedTools"
    }.freeze
    private_constant :TOOL_SCOPE_FLAGS_UNSET, :LEGACY_CLAUDE_TOOL_SCOPE_FLAGS

    STATUS_DETECTION_MODES =
      %i[state_file_marker exit_code_only output_file_exists].freeze

    RoutingArguments = Data.define(
      :profile_name, :stage, :model, :effort, :provenance,
      :global_arguments, :subcommand_arguments
    ) do
      def initialize(profile_name:, stage:, model:, effort:, provenance:,
                     global_arguments:, subcommand_arguments:)
        super(
          profile_name: profile_name.to_sym,
          stage: stage.to_s.dup.freeze,
          model: model&.to_s&.dup&.freeze,
          effort: effort&.to_s&.dup&.freeze,
          provenance: provenance.dup.freeze,
          global_arguments: freeze_arguments(global_arguments),
          subcommand_arguments: freeze_arguments(subcommand_arguments)
        )
        freeze
      end

      def native_arguments
        global_arguments + subcommand_arguments
      end

      private

      def freeze_arguments(arguments)
        Array(arguments).map { |argument| argument.to_s.dup.freeze }.freeze
      end
    end

    attr_reader :runtime_profile, :env_bin_override_key,
                :skill_syntax_format, :headless_supported,
                :status_detection_mode, :initial_context_tokens,
                :default_model_resolver, :policy_capabilities,
                :routed_effort_values, :routing_argument_placement,
                :routed_model_argument_builder, :routed_effort_argument_builder,
                :structured_output_protocol, :cli_capabilities,
                :permission_presets, :opencode_configuration_path,
                :opencode_configuration, :opencode_credential_environment_keys,
                :opencode_credential_file, :opencode_plugins, :opencode_pure,
                :billing_semantics

    # Existing custom profile registrations remain source compatible. Shipped
    # profiles pass runtime_profile: so their compatibility definition comes
    # directly from agent-cli-runtime rather than being repeated in Hive.
    def initialize(name: nil, bin_default: nil, headless_flag: nil,
                   version_flag: nil, skill_syntax_format:,
                   runtime_profile: nil, env_bin_override_key: nil,
                   auth_configuration_required: false,
                   permission_skip_flag: nil, add_dir_flag: nil,
                   budget_flag: nil, output_format_flags: [],
                   headless_supported: true, min_version: nil,
                   status_detection_mode: :output_file_exists,
                   preflight: nil, usage_extractor: nil, skill_verifier: nil,
                   workspace_write_flags: nil, read_only_flags: nil,
                   cli_capabilities: {}, initial_context_tokens: 0,
                   prompt_style: nil, default_model_resolver: nil,
                   model_argument_builder: nil, effort_argument_builder: nil,
                   launcher_identity: nil, policy_capabilities: [],
                   routed_effort_values: nil,
                   routing_argument_placement: :subcommand,
                   routed_model_argument_builder: nil,
                   routed_effort_argument_builder: nil,
                   tool_scope_flags: TOOL_SCOPE_FLAGS_UNSET,
                   raw_cli_arguments_supported: false,
                   structured_output_protocol: nil,
                   billing_semantics: :unknown,
                   credential_environment_keys: [],
                   configuration_environment_key: nil,
                   default_configuration_directory: nil,
                   permission_presets: nil,
                   opencode_configuration_path: nil,
                   opencode_configuration: nil,
                   opencode_credential_environment_keys: [],
                   opencode_credential_file: nil,
                   opencode_plugins: [], opencode_pure: true)
      effective_name = runtime_profile&.name || name
      raise ArgumentError, "missing keyword: :name" if effective_name.nil?

      prompt_style ||= effective_name.to_sym == :codex ? :stdin : :positional
      validate_hive_policy!(
        prompt_style:, status_detection_mode:, initial_context_tokens:,
        routing_argument_placement:, structured_output_protocol:
      )

      scope_flags =
        if tool_scope_flags.equal?(TOOL_SCOPE_FLAGS_UNSET)
          effective_name.to_sym == :claude ? LEGACY_CLAUDE_TOOL_SCOPE_FLAGS : {}
        else
          tool_scope_flags
        end
      normalized_cli_capabilities = normalize_cli_capabilities(cli_capabilities)

      @runtime_profile = runtime_profile || AgentCliRuntime::Profile.new(
        name: effective_name,
        bin_default: required_runtime_value(bin_default, :bin_default),
        env_bin_override_keys: Array(env_bin_override_key).compact,
        headless_flag: required_runtime_value(headless_flag, :headless_flag),
        permission_skip_flag: permission_skip_flag,
        workspace_write_flags: Array(workspace_write_flags),
        read_only_flags: Array(read_only_flags),
        add_dir_flag: add_dir_flag,
        tool_scope_flags: scope_flags,
        budget_flag: budget_flag,
        output_format_flags: output_format_flags,
        version_flag: required_runtime_value(version_flag, :version_flag),
        min_version: min_version,
        prompt_style: prompt_style,
        model_argument_builder: model_argument_builder,
        effort_argument_builder: effort_argument_builder,
        launcher_identity: launcher_identity || "AgentProfile/v1:#{effective_name}",
        usage_extractor: usage_extractor,
        cli_capabilities: normalized_cli_capabilities,
        raw_cli_arguments_supported: raw_cli_arguments_supported,
        credential_environment_keys: credential_environment_keys,
        configuration_environment_key: configuration_environment_key,
        default_configuration_directory: default_configuration_directory
      )
      unless @runtime_profile.is_a?(AgentCliRuntime::Profile)
        raise ArgumentError,
              "runtime_profile must be an AgentCliRuntime::Profile"
      end

      @env_bin_override_key =
        env_bin_override_key || @runtime_profile.env_bin_override_keys.find do |key|
          key.start_with?("HIVE_")
        end
      @auth_configuration_required = auth_configuration_required == true
      @skill_syntax_format = skill_syntax_format
      @headless_supported = headless_supported == true
      @status_detection_mode = status_detection_mode
      @preflight = preflight
      @skill_verifier = skill_verifier
      @cli_capabilities = normalized_cli_capabilities
      @initial_context_tokens = initial_context_tokens
      @default_model_resolver = default_model_resolver
      @policy_capabilities = Array(policy_capabilities).map(&:to_sym).uniq.freeze
      @routed_effort_values =
        routed_effort_values && Array(routed_effort_values)
          .map { |value| value.to_s.freeze }.uniq.freeze
      @routing_argument_placement = routing_argument_placement
      @routed_model_argument_builder =
        routed_model_argument_builder || @runtime_profile.model_argument_builder
      @routed_effort_argument_builder =
        routed_effort_argument_builder || @runtime_profile.effort_argument_builder
      @structured_output_protocol = structured_output_protocol&.to_sym
      @permission_presets = normalize_permission_presets(
        permission_presets ||
          (effective_name.to_sym == :claude ? %w[read-only scoped] : [])
      )
      if opencode_configuration_path && opencode_configuration
        raise ArgumentError,
              "choose opencode_configuration_path or opencode_configuration, not both"
      end
      @opencode_configuration_path =
        opencode_configuration_path&.to_s&.dup&.freeze
      @opencode_configuration =
        if opencode_configuration
          deep_freeze_hash(opencode_configuration).tap do |configuration|
            validate_nonsecret_opencode_configuration!(configuration)
          end
        end
      @opencode_credential_environment_keys = normalize_environment_keys(
        opencode_credential_environment_keys
      )
      @opencode_credential_file = opencode_credential_file&.to_s&.dup&.freeze
      @opencode_plugins = normalize_opencode_plugins(opencode_plugins)
      @opencode_pure = opencode_pure != false
      @billing_semantics = billing_semantics.to_sym
      unless BILLING_SEMANTICS.include?(@billing_semantics)
        raise ArgumentError,
              "billing_semantics must be one of #{BILLING_SEMANTICS.inspect}"
      end
      freeze
    end

    %i[
      name bin_default headless_flag permission_skip_flag workspace_write_flags
      read_only_flags add_dir_flag tool_scope_flags budget_flag
      output_format_flags version_flag min_version prompt_style
      model_argument_builder effort_argument_builder launcher_identity
      credential_environment_keys configuration_environment_key
      default_configuration_directory
    ].each do |method_name|
      define_method(method_name) { @runtime_profile.public_send(method_name) }
    end

    def bin
      @runtime_profile.bin(env: ENV)
    end

    def permission_flags(permission_mode = nil)
      @runtime_profile.permission_flags(permission_mode)
    end

    def workspace_write_supported?
      !workspace_write_flags.empty?
    end

    def read_only_supported?
      !read_only_flags.empty?
    end

    def raw_cli_arguments_supported?
      @runtime_profile.raw_cli_arguments_supported?
    end

    def permission_preset_supported?(preset)
      @permission_presets.include?(preset.to_s)
    end

    def auth_configuration_required?
      @auth_configuration_required
    end

    # Hive launches CLI subscriptions/sessions only. The compatibility
    # package inventories every ambient provider credential name so Hive can
    # remove it without keeping a second provider-specific list.
    def subscription_environment(unset_value: nil)
      credential_environment_keys.reject { |key| key.end_with?("_AUTH_PATH") }.to_h do |key|
        [ key, unset_value ]
      end.freeze
    end

    def configuration_directory(home: nil, environment: ENV)
      @runtime_profile.configuration_directory(home:, env: environment)
    end

    def verify_skill(invocation, project_root: nil)
      return [ :not_applicable, "no skill verifier configured for this profile" ] unless @skill_verifier

      kwargs = { project_root: project_root }
      if name == :opencode
        kwargs[:configuration_path] = @opencode_configuration_path if
          @opencode_configuration_path
        kwargs[:configuration] = @opencode_configuration if @opencode_configuration
        kwargs[:plugins] = @opencode_plugins unless @opencode_plugins.empty?
      end
      @skill_verifier.call(invocation, **kwargs)
    end

    def format_skill_invocation(skill)
      raw = normalize_legacy_compound_engineering_invocation(skill.to_s)
      if raw.start_with?("/")
        return raw if @skill_syntax_format == "/%{skill}"

        raw = raw.delete_prefix("/")
      end
      if @skill_syntax_format != "/%{skill}" && raw.include?(":")
        raw = raw.split(":", 2).last
      end
      format(@skill_syntax_format, skill: raw)
    end

    def normalize_legacy_compound_engineering_invocation(raw)
      raw.sub(%r{\A/?compound-engineering:(ce-[A-Za-z0-9-]+)\z}, '\1')
    end

    def concrete_default_model(cfg: nil, project_root: nil, home: nil)
      unless @default_model_resolver
        raise Hive::ImplementationIdentity::ResolutionError,
              "agent profile #{name.inspect} cannot resolve a concrete default model"
      end

      value = @default_model_resolver.call(cfg:, project_root:, home:)
      Hive::ImplementationIdentity.normalize_model(value, concrete: true)
    rescue Hive::ImplementationIdentity::Error
      raise
    rescue StandardError => e
      raise Hive::ImplementationIdentity::ResolutionError,
            "agent profile #{name.inspect} default-model resolution failed: #{e.message}"
    end

    # Keep Hive's durable identity value and its stricter model syntax while
    # delegating native argument rendering to the package profile.
    def identity_arguments(model:, effort:, pin_model: true)
      normalized_model =
        Hive::ImplementationIdentity.normalize_model(model, concrete: true)
      requested_effort = Hive::ImplementationIdentity.normalize_effort(effort)
      package_identity = @runtime_profile.identity_arguments(
        model: normalized_model,
        effort: effort_argument_builder ? requested_effort : nil,
        pin_model: pin_model
      )
      native_arguments = Hive::ImplementationIdentity.validate_native_arguments(
        package_identity.native_arguments
      )

      Hive::ImplementationIdentity::LaunchArguments.new(
        model: normalized_model,
        requested_effort: requested_effort,
        effective_effort: package_identity.effective_effort,
        effort_supported: package_identity.effort_supported,
        model_pinned: package_identity.model_pinned,
        native_arguments: native_arguments
      )
    rescue AgentCliRuntime::UnsupportedCapability => e
      message =
        if e.message.include?("cannot pin a model")
          "agent profile #{name.inspect} cannot pin model #{normalized_model.inspect}"
        else
          e.message
        end
      raise Hive::ImplementationIdentity::ResolutionError, message, cause: e
    rescue ArgumentError => e
      raise unless name == :opencode

      raise Hive::ImplementationIdentity::ResolutionError,
            "agent profile :opencode requires an exact provider/model route: #{e.message}",
            cause: e
    end

    def validate_routed_control!(control, source: nil)
      unless control.is_a?(Hive::ModelRouting::EffectiveControl)
        raise ArgumentError,
              "routed control must be a Hive::ModelRouting::EffectiveControl"
      end

      value = normalize_routed_value(control.value, control_path(control, source))
      case control.field
      when :model
        if name == :opencode
          begin
            value = AgentCliRuntime::Route.parse(value).to_s
          rescue ArgumentError => e
            raise Hive::ConfigError,
                  "#{control_path(control, source)} must be an exact OpenCode " \
                  "provider/model route: #{e.message}"
          end
        end
        return value if @routed_model_argument_builder

        raise Hive::ConfigError,
              "#{control_path(control, source)} requests model selection, but agent profile " \
              "#{name.inspect} does not support model selection"
      when :effort
        unless @routed_effort_argument_builder
          raise Hive::ConfigError,
                "#{control_path(control, source)} requests reasoning effort, but agent profile " \
                "#{name.inspect} does not support reasoning effort"
        end
        if @routed_effort_values && !@routed_effort_values.include?(value)
          raise Hive::ConfigError,
                "#{control_path(control, source)} for agent profile #{name.inspect} must be one of " \
                "#{@routed_effort_values.inspect}; got #{control.value.inspect}"
        end
        value
      else
        raise ArgumentError, "unknown routed control field #{control.field.inspect}"
      end
    end

    def routing_arguments(resolution, source: nil)
      unless resolution.is_a?(Hive::ModelRouting::Resolution)
        raise ArgumentError,
              "routing resolution must be a Hive::ModelRouting::Resolution"
      end
      return nil unless resolution.active?
      if resolution.provider && resolution.provider.to_s != name.to_s
        raise Hive::ConfigError,
              "model routing selected provider #{resolution.provider.inspect}, but agent profile " \
              "#{name.inspect} was chosen; models may not change providers"
      end

      Hive::ModelRouting.fetch(resolution.stage)
      Hive::ModelRouting::FIELDS.each do |field|
        provenance = resolution.provenance.fetch(field)
        next unless provenance.routed?

        validate_routed_control!(
          Hive::ModelRouting::EffectiveControl.new(
            stage: resolution.stage, profile: name, provider: resolution.provider,
            field: field, value: resolution.public_send(field), provenance: provenance
          ),
          source:
        )
      end

      native_arguments = []
      append_routing_argument(
        native_arguments, @routed_model_argument_builder, resolution.model, "model"
      )
      append_routing_argument(
        native_arguments, @routed_effort_argument_builder, resolution.effort, "effort"
      )
      native_arguments =
        Hive::ImplementationIdentity.validate_native_arguments(native_arguments)
      global_arguments =
        @routing_argument_placement == :global ? native_arguments : []
      subcommand_arguments =
        @routing_argument_placement == :subcommand ? native_arguments : []

      RoutingArguments.new(
        profile_name: name, stage: resolution.stage, model: resolution.model,
        effort: resolution.effort, provenance: resolution.provenance,
        global_arguments:, subcommand_arguments:
      )
    end

    def validate_routing_arguments!(arguments)
      unless arguments.is_a?(RoutingArguments)
        raise ArgumentError,
              "routing_arguments must be an AgentProfile::RoutingArguments"
      end
      unless arguments.profile_name == name.to_sym
        raise ArgumentError,
              "routing arguments for profile #{arguments.profile_name.inspect} " \
              "cannot be used with #{name.inspect}"
      end

      Hive::ModelRouting.fetch(arguments.stage)
      expected = routing_arguments(
        Hive::ModelRouting::Resolution.new(
          stage: arguments.stage, provider: name, model: arguments.model,
          effort: arguments.effort, provenance: arguments.provenance
        )
      )
      unless expected == arguments
        raise ArgumentError,
              "routing arguments do not match agent profile #{name.inspect} native rendering"
      end
      arguments
    end

    def require_cli_capability!(capability)
      capability_name = capability.to_sym
      flags = @cli_capabilities[capability_name]
      unless flags
        raise Hive::AgentError,
              "agent profile #{name.inspect} does not declare CLI capability " \
              "#{capability_name.inspect}"
      end

      check_version!
      profile = capability_runtime_profile
      AgentCliRuntime.require_capability!(profile, capability_name).arguments
    rescue Hive::AgentError
      raise
    rescue AgentCliRuntime::Error => e
      raise Hive::AgentError, e.message, cause: e
    end

    RUNTIME_OVERRIDE_KEYS = {
      "bin" => :bin_default,
      "env_override" => :env_bin_override_key,
      "min_version" => :min_version
    }.freeze
    OPENCODE_OVERRIDE_KEYS = {
      "config_path" => :opencode_configuration_path,
      "config" => :opencode_configuration,
      "credential_env" => :opencode_credential_environment_keys,
      "credential_file" => :opencode_credential_file,
      "plugins" => :opencode_plugins,
      "isolation" => :opencode_isolation
    }.freeze

    def with_overrides(overrides_hash)
      return self if overrides_hash.nil? || overrides_hash.empty?
      unless overrides_hash.is_a?(Hash)
        raise Hive::ConfigError,
              "agents.#{name} override must be a Hash; got #{overrides_hash.class}"
      end

      runtime_overrides = {}
      policy_overrides = {}
      overrides_hash.each do |key, value|
        normalized_key = key.to_s
        if (kwarg = RUNTIME_OVERRIDE_KEYS[normalized_key])
          runtime_overrides[kwarg] = value
          next
        end
        if name == :opencode &&
           (kwarg = OPENCODE_OVERRIDE_KEYS[normalized_key])
          if kwarg == :opencode_isolation
            unless value.to_s == "hermetic"
              raise Hive::ConfigError,
                    "agents.opencode.isolation must be hermetic"
            end
          else
            policy_overrides[kwarg] = value
          end
          next
        end

        known = RUNTIME_OVERRIDE_KEYS.keys
        known += OPENCODE_OVERRIDE_KEYS.keys if name == :opencode
        raise Hive::ConfigError,
              "agents.#{name}.#{key} is not a recognized override key " \
              "(known: #{known.inspect})"
      end

      overridden_runtime = RuntimeProfileOverride.new(
        @runtime_profile,
        bin_default: runtime_overrides.fetch(:bin_default, bin_default),
        env_bin_override_key:
          runtime_overrides.fetch(:env_bin_override_key, @env_bin_override_key),
        min_version: runtime_overrides.fetch(:min_version, min_version)
      )
      self.class.new(
        **construction_kwargs.merge(
          **policy_overrides,
          runtime_profile: overridden_runtime,
          env_bin_override_key:
            runtime_overrides.fetch(:env_bin_override_key, @env_bin_override_key)
        )
      )
    end

    def check_version!
      cache_key = [ bin, min_version ]
      cached = self.class.send(:version_cache)[cache_key]
      return cached if cached

      unless @headless_supported
        raise Hive::AgentError,
              "agent profile #{name.inspect} is not headless-supported; " \
              "cannot run from a non-interactive context"
      end

      version = @runtime_profile.check_version!(env: ENV)
      self.class.send(:version_cache)[cache_key] = version
    rescue AgentCliRuntime::Error => e
      raise Hive::AgentError, e.message, cause: e
    end

    def preflight!
      @preflight&.call
      nil
    end

    def extract_error_event(event)
      @runtime_profile.extract_error_event(event)
    end

    def extract_usage_event(event)
      @runtime_profile.extract_usage_event(event)
    rescue StandardError
      nil
    end

    class << self
      def reset_version_cache!
        @version_cache = nil
      end

      private

      def version_cache
        @version_cache ||= {}
      end
    end

    private

    def required_runtime_value(value, keyword)
      return value unless value.nil?

      raise ArgumentError, "missing keyword: :#{keyword}"
    end

    def validate_hive_policy!(prompt_style:, status_detection_mode:,
                              initial_context_tokens:,
                              routing_argument_placement:,
                              structured_output_protocol:)
      unless PROMPT_STYLES.include?(prompt_style)
        raise ArgumentError,
              "unknown prompt_style: #{prompt_style.inspect}; valid: #{PROMPT_STYLES.inspect}"
      end
      unless STATUS_DETECTION_MODES.include?(status_detection_mode)
        raise ArgumentError,
              "unknown status_detection_mode: #{status_detection_mode.inspect}; " \
              "valid: #{STATUS_DETECTION_MODES.inspect}"
      end
      unless initial_context_tokens.is_a?(Integer) && initial_context_tokens >= 0
        raise ArgumentError,
              "initial_context_tokens must be a non-negative Integer"
      end
      unless ROUTING_ARGUMENT_PLACEMENTS.include?(routing_argument_placement)
        raise ArgumentError,
              "unknown routing_argument_placement: #{routing_argument_placement.inspect}; " \
              "valid: #{ROUTING_ARGUMENT_PLACEMENTS.inspect}"
      end
      return unless structured_output_protocol &&
                    !STRUCTURED_OUTPUT_PROTOCOLS.include?(structured_output_protocol.to_sym)

      raise ArgumentError,
            "unknown structured_output_protocol: #{structured_output_protocol.inspect}; " \
            "valid: #{STRUCTURED_OUTPUT_PROTOCOLS.inspect}"
    end

    def normalize_cli_capabilities(capabilities)
      unless capabilities.is_a?(Hash)
        raise ArgumentError,
              "cli_capabilities must be a Hash; got #{capabilities.class}"
      end

      capabilities.each_with_object({}) do |(capability_name, raw_flags), normalized|
        flags = Array(raw_flags).map(&:to_s).reject(&:empty?)
        if flags.empty?
          raise ArgumentError,
                "CLI capability #{capability_name.inspect} must declare at least one flag"
        end
        normalized[capability_name.to_sym] = flags.freeze
      end.freeze
    end

    def capability_runtime_profile
      AgentCliRuntime::Profile.new(
        name: name, bin_default: bin_default,
        env_bin_override_keys: @runtime_profile.env_bin_override_keys,
        headless_flag: headless_flag, version_flag: version_flag,
        min_version: min_version, cli_capabilities: @cli_capabilities
      )
    end

    def construction_kwargs
      {
        skill_syntax_format: @skill_syntax_format,
        env_bin_override_key: @env_bin_override_key,
        auth_configuration_required: @auth_configuration_required,
        headless_supported: @headless_supported,
        status_detection_mode: @status_detection_mode,
        preflight: @preflight,
        skill_verifier: @skill_verifier,
        cli_capabilities: @cli_capabilities.transform_values(&:dup),
        initial_context_tokens: @initial_context_tokens,
        default_model_resolver: @default_model_resolver,
        policy_capabilities: @policy_capabilities.dup,
        routed_effort_values: @routed_effort_values&.dup,
        routing_argument_placement: @routing_argument_placement,
        routed_model_argument_builder: @routed_model_argument_builder,
        routed_effort_argument_builder: @routed_effort_argument_builder,
        structured_output_protocol: @structured_output_protocol,
        permission_presets: @permission_presets.dup,
        opencode_configuration_path: @opencode_configuration_path,
        opencode_configuration: @opencode_configuration,
        opencode_credential_environment_keys:
          @opencode_credential_environment_keys.dup,
        opencode_credential_file: @opencode_credential_file,
        opencode_plugins: @opencode_plugins.dup,
        opencode_pure: @opencode_pure,
        billing_semantics: @billing_semantics
      }
    end

    def append_routing_argument(arguments, builder, value, field)
      return unless builder && !value.nil?

      normalized = normalize_routed_value(value, "effective routed #{field}")
      arguments.concat(Array(builder.call(normalized)))
    end

    def normalize_routed_value(value, path)
      unless value.is_a?(String) || value.is_a?(Symbol)
        raise Hive::ConfigError,
              "#{path} must be a non-blank scalar; got #{value.inspect}"
      end

      normalized = value.to_s.strip
      raise Hive::ConfigError, "#{path} must be a non-blank scalar" if normalized.empty?

      normalized
    end

    def normalize_permission_presets(values)
      presets = Array(values).map(&:to_s).uniq
      invalid = presets - %w[read-only scoped]
      unless invalid.empty?
        raise ArgumentError,
              "unknown permission preset #{invalid.first.inspect}"
      end
      presets.freeze
    end

    def normalize_environment_keys(values)
      keys = Array(values).map { |value| value.to_s.dup.freeze }
      invalid = keys.find { |key| !key.match?(/\A[A-Z][A-Z0-9_]*\z/) }
      raise ArgumentError, "invalid OpenCode credential environment key" if invalid
      raise ArgumentError, "OpenCode credential environment keys must be unique" if
        keys.uniq.length != keys.length

      keys.freeze
    end

    def normalize_opencode_plugins(values)
      unless values.is_a?(Array)
        raise ArgumentError, "OpenCode plugins must be an array"
      end
      plugins = values.map { |plugin| plugin.to_s.dup.freeze }
      if plugins.any?(&:empty?)
        raise ArgumentError, "OpenCode plugins must be non-empty strings"
      end
      if plugins.uniq.length != plugins.length
        raise ArgumentError, "OpenCode plugins must be unique"
      end

      plugins.freeze
    end

    def deep_freeze_hash(value)
      unless value.is_a?(Hash)
        raise ArgumentError, "opencode_configuration must be a Hash"
      end

      JSON.parse(JSON.generate(value)).tap do |copy|
        deep_freeze_value(copy)
      end
    rescue JSON::GeneratorError
      raise ArgumentError, "opencode_configuration must contain JSON values"
    end

    def deep_freeze_value(value)
      case value
      when Hash
        value.each { |key, item| key.freeze; deep_freeze_value(item) }
      when Array
        value.each { |item| deep_freeze_value(item) }
      when String
        value.freeze
      end
      value.freeze
    end

    def validate_nonsecret_opencode_configuration!(value, key = nil)
      case value
      when Hash
        value.each do |child_key, child|
          validate_nonsecret_opencode_configuration!(child, child_key)
        end
      when Array
        value.each { |child| validate_nonsecret_opencode_configuration!(child, key) }
      when String
        if key.to_s.match?(/(?:api[_-]?key|token|secret|password|credential)/i) &&
           !value.match?(/\A\{env:[A-Z][A-Z0-9_]*\}\z/)
          raise ArgumentError,
                "OpenCode provider definitions cannot contain credential values"
        end
      end
    end

    def control_path(control, source)
      key = control.provenance.key || control.stage
      path = "models.#{key}.#{control.field}"
      path = "#{path} effective for #{control.stage}" if key.to_s != control.stage.to_s
      source ? "#{path} in #{source}" : path
    end

    # Package Profile is intentionally immutable. This typed proxy preserves
    # the published provider behavior while applying Hive's three supported
    # project-local executable/version overrides.
    class RuntimeProfileOverride < AgentCliRuntime::Profile
      DELEGATED_METHODS = %i[
        name env_bin_override_keys headless_flag permission_skip_flag
        workspace_write_flags read_only_flags add_dir_flag tool_scope_flags
        budget_flag output_format_flags version_flag prompt_style
        model_argument_builder effort_argument_builder launcher_identity
        cli_capabilities declared_capability_support
        credential_environment_keys configuration_environment_key
        default_configuration_directory permission_policy_required result_parser
        permission_flags identity_arguments
        raw_cli_arguments_supported? auth_configuration extract_usage_event
        extract_error_event
        configuration_directory parse_run normalize_captured_result
      ].freeze

      def initialize(base, bin_default:, env_bin_override_key:, min_version:)
        @base = base
        @bin_default_override = bin_default.to_s.dup.freeze
        # Keep the package-owned override keys as fallbacks. OpenCode
        # preparation pins the already-resolved executable through the
        # package's AGENT_CLI_RUNTIME_* key; replacing the inventory with a
        # Hive-only config key would make that private route probe look for a
        # different binary after preparation had already resolved one.
        @env_bin_override_keys = [
          *Array(env_bin_override_key), *base.env_bin_override_keys
        ].compact.map { |key| key.to_s.dup.freeze }.uniq.freeze
        @min_version_override = min_version&.to_s&.dup&.freeze
        freeze
      end

      attr_reader :env_bin_override_keys

      DELEGATED_METHODS.each do |method_name|
        next if method_name == :env_bin_override_keys

        define_method(method_name) do |*args, **kwargs, &block|
          @base.public_send(method_name, *args, **kwargs, &block)
        end
      end

      def bin_default
        @bin_default_override
      end

      def min_version
        @min_version_override
      end

      def bin(env: ENV)
        key = @env_bin_override_keys.find { |candidate| !env[candidate].to_s.empty? }
        key ? env.fetch(key) : @bin_default_override
      end

      def check_version!(env: ENV)
        profile = AgentCliRuntime::Profile.new(
          name: name, bin_default: @bin_default_override,
          env_bin_override_keys: @env_bin_override_keys,
          headless_flag: headless_flag, version_flag: version_flag,
          min_version: @min_version_override
        )
        profile.check_version!(env:)
      end

      def require_cli_capability!(capability)
        profile = AgentCliRuntime::Profile.new(
          name: name, bin_default: @bin_default_override,
          env_bin_override_keys: @env_bin_override_keys,
          headless_flag: headless_flag, version_flag: version_flag,
          min_version: @min_version_override,
          cli_capabilities: cli_capabilities
        )
        profile.require_cli_capability!(capability)
      end
    end
    private_constant :RuntimeProfileOverride
  end
end
