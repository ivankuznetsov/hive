module AgentCliRuntime
  module Runtime
    module_function

    def compile(request)
      unless request.is_a?(Request)
        raise ArgumentError,
              "request must be an AgentCliRuntime::Request"
      end

      profile = Profiles.resolve(request.profile)
      evidence = [ supported_evidence(profile, :headless) ]
      argv = [ request.executable || profile.bin ]
      prompt_style = profile.prompt_style
      argv << profile.headless_flag
      argv << request.prompt if prompt_style == :headless_flag_value

      argv.concat(
        permission_arguments(
          profile, request.permission_mode, evidence,
          trusted_arguments: request.permission_arguments
        )
      )
      argv.concat(directory_arguments(profile, request, evidence))
      argv.concat(tool_scope_arguments(profile, request, evidence))
      argv.concat(budget_arguments(profile, request.max_budget_usd, evidence))
      argv.concat(identity_arguments(profile, request, evidence))

      request.capabilities.each do |capability|
        capability_evidence = require_capability!(profile, capability)
        evidence << capability_evidence
        argv.concat(capability_evidence.arguments)
      end

      unless request.raw_cli_arguments.empty?
        unless profile.raw_cli_arguments_supported?
          unsupported!(
            profile, :raw_cli_arguments,
            "agent profile #{profile.name.inspect} does not accept raw CLI arguments"
          )
        end
        evidence << supported_evidence(
          profile, :raw_cli_arguments, request.raw_cli_arguments
        )
        argv.concat(request.raw_cli_arguments)
      end
      argv.concat(request.trusted_cli_arguments)
      argv.concat(profile.output_format_flags) if request.include_output_format
      stdin_data =
        case prompt_style
        when :positional
          argv << request.prompt
          nil
        when :headless_flag_value
          nil
        when :stdin
          argv << "-"
          request.prompt
        when :piped_stdin
          request.prompt
        end

      CompiledInvocation.new(
        argv: request.command_prefix + argv,
        stdin_data:,
        provider: profile.name,
        launcher_identity: profile.launcher_identity,
        capability_evidence: evidence
      )
    rescue Error
      raise
    rescue StandardError => e
      profile = Profiles.resolve(request.profile) if request.is_a?(Request)
      compilation_error!(profile, e)
    end

    def prepare!(profile, env: ENV)
      if profile.is_a?(OpenCodePreparationRequest)
        return OpenCode::Overlay.prepare!(profile, env:)
      end

      resolved = Profiles.resolve(profile)
      result = Probe.call(resolved, env:)
      return result if result.ready

      evidence = unsupported_evidence(
        resolved, :probe, result.diagnostic || "local prerequisites unavailable"
      )
      raise ProbeError.new(
        "agent profile #{resolved.name.inspect} probe failed: #{evidence.diagnostic}",
        evidence: evidence
      )
    end

    def require_capability!(profile, capability)
      resolved = Profiles.resolve(profile)
      arguments = resolved.require_cli_capability!(capability)
      supported_evidence(resolved, capability, arguments)
    rescue UnknownProvider
      raise
    rescue Error => e
      evidence = unsupported_evidence(
        resolved, capability, Redactor.diagnostic(e)
      )
      raise UnsupportedCapability.new(
        "agent profile #{resolved.name.inspect} cannot provide " \
        "#{capability.to_sym.inspect}: #{evidence.diagnostic}",
        evidence: evidence
      ), cause: e
    end

    def extract_usage(profile, event)
      resolved = Profiles.resolve(profile)
      begin
        normalize_usage(resolved.extract_usage_event(event))
      rescue StandardError
        nil
      end
    end

    # A provider failure seen mid-stream, normalized to
    # {kind:, provider:, status_code:, message:}, or nil when the event is
    # clean. Callers use this to tell a provider-side stop (quota, credit
    # ceiling, rate limit, model output truncation) apart from an agent that
    # genuinely produced nothing: several CLIs report the former on the stream
    # and still exit zero.
    def extract_provider_error(profile, event)
      resolved = Profiles.resolve(profile)
      extracted = resolved.extract_error_event(event)
      return nil if extracted.nil?

      kind, text = normalize_extracted_error(extracted)
      return nil if text.nil? || text.strip.empty?

      {
        kind: kind,
        provider: resolved.name,
        status_code: status_code_from(text),
        message: Redactor.diagnostic(text)
      }.freeze
    end

    def normalize_extracted_error(extracted)
      return [ extracted.kind, extracted.message ] if extracted.is_a?(ExtractedFailure)
      return [ failure_kind_from(extracted), extracted ] if extracted.is_a?(String)

      [ nil, nil ]
    end
    private_class_method :normalize_extracted_error

    def failure_kind_from(text)
      status = status_code_from(text)
      return :provider_limit if status == 402
      return :rate_limited if status == 429

      normalized = text.to_s.downcase
      return :rate_limited if normalized.match?(/\brate[\s_-]*limit(?:ed|s)?\b/)
      return :provider_limit if normalized.match?(
        /\b(?:quota|billing|credits?|tokens?[\s_-]*limit|usage[\s_-]*limit)\b/
      )

      :provider_error
    end
    private_class_method :failure_kind_from

    def observe(profile, result)
      resolved = Profiles.resolve(profile)
      raw = result.is_a?(Hash) ? result : {}
      ObservableResult.new(
        provider: resolved.name,
        launcher_identity: resolved.launcher_identity,
        exit_code: raw[:exit_code],
        timed_out: raw[:timed_out],
        status: raw[:status],
        usage: normalize_usage(raw[:usage]),
        final_message: raw[:final_message],
        diagnostic: Redactor.diagnostic(
          raw[:error_message] || raw[:limit_text]
        ),
        provider_signal: raw[:provider_signal]
      )
    end

    def parse_run(profile, stdout:)
      Profiles.resolve(profile).parse_run(stdout)
    end

    def normalize(profile, captured, requested_route:)
      Profiles.resolve(profile).normalize_captured_result(
        captured, requested_route:
      )
    end

    def supported_evidence(profile, capability, arguments = [])
      CapabilityEvidence.new(
        capability: capability,
        supported: true,
        provider: profile.name,
        launcher_identity: profile.launcher_identity,
        arguments: arguments
      )
    end

    def unsupported_evidence(profile, capability, diagnostic)
      CapabilityEvidence.new(
        capability: capability,
        supported: false,
        provider: profile&.name || :unknown,
        launcher_identity: profile&.launcher_identity || "unknown",
        diagnostic: Redactor.diagnostic(diagnostic)
      )
    end

    def permission_arguments(profile, permission_mode, evidence,
                             trusted_arguments: nil)
      arguments =
        if trusted_arguments
          trusted_arguments
        else
          profile.permission_flags(permission_mode)
        end
      capability =
        permission_mode&.tr("-", "_")&.to_sym || :permission_bypass
      evidence << supported_evidence(profile, capability, arguments)
      arguments
    rescue ArgumentError => e
      unsupported!(
        profile, permission_mode&.tr("-", "_")&.to_sym || :permission, e
      )
    end
    private_class_method :permission_arguments

    def directory_arguments(profile, request, evidence)
      return [] if request.add_dirs.empty?

      unless profile.add_dir_flag
        if request.require_add_dirs
          unsupported!(
            profile, :add_directory,
            "agent profile #{profile.name.inspect} cannot constrain additional directories"
          )
        end
        evidence << unsupported_evidence(
          profile, :add_directory,
          "unsupported; directories intentionally omitted"
        )
        return []
      end

      arguments =
        request.add_dirs.flat_map { |directory| [ profile.add_dir_flag, directory ] }
      evidence << supported_evidence(profile, :add_directory, arguments)
      arguments
    end
    private_class_method :directory_arguments

    def tool_scope_arguments(profile, request, evidence)
      arguments = []
      {
        allowed_tools: [ request.allowed_tools, :allowed ],
        disallowed_tools: [ request.disallowed_tools, :disallowed ]
      }.each do |capability, (tools, scope)|
        value = tool_csv(tools)
        next unless value

        flag = profile.tool_scope_flags[scope]
        unless flag
          unsupported!(
            profile, capability,
            "agent profile #{profile.name.inspect} cannot enforce #{scope} tool scope"
          )
        end
        scoped_arguments = [ flag, value ]
        evidence << supported_evidence(profile, capability, scoped_arguments)
        arguments.concat(scoped_arguments)
      end
      arguments
    end
    private_class_method :tool_scope_arguments

    def budget_arguments(profile, max_budget_usd, evidence)
      return [] if max_budget_usd.nil?
      unless profile.budget_flag
        unsupported!(
          profile, :budget,
          "agent profile #{profile.name.inspect} cannot enforce a native budget"
        )
      end

      arguments = [ profile.budget_flag, max_budget_usd.to_s ]
      evidence << supported_evidence(profile, :budget, arguments)
      arguments
    end
    private_class_method :budget_arguments

    def identity_arguments(profile, request, evidence)
      arguments = request.identity_arguments.dup
      return arguments unless request.model || request.effort
      unless request.model
        unsupported!(
          profile, :effort,
          "effort requires an explicit model in an invocation request"
        )
      end

      identity = profile.identity_arguments(
        model: request.model,
        effort: request.effort,
        pin_model: request.pin_model
      )
      evidence << supported_evidence(profile, :model, identity.native_arguments)
      evidence << supported_evidence(profile, :effort) if request.effort
      arguments.concat(identity.native_arguments)
    rescue UnsupportedCapability => e
      capability = request.effort && !profile.effort_argument_builder ? :effort : :model
      unsupported!(profile, capability, e)
    end
    private_class_method :identity_arguments

    def tool_csv(tools)
      values = Array(tools).compact.map(&:to_s).reject(&:empty?).uniq
      values.empty? ? nil : values.join(",")
    end
    private_class_method :tool_csv

    # Providers prefix the status onto the text ("402: {...}") or carry it in
    # the embedded payload. Either is enough to classify without matching on
    # human-readable wording, which differs per provider and changes freely.
    def status_code_from(text)
      value = text[/\A\s*(\d{3})\s*:/, 1] || text[/"code"\s*:\s*(\d{3})\b/, 1]
      code = value.to_i
      code.between?(100, 599) ? code : nil
    end
    private_class_method :status_code_from

    def normalize_usage(usage)
      return nil unless usage.is_a?(Hash)

      value = ->(key) { usage.key?(key) ? usage[key] : usage[key.to_s] }
      {
        input: normalized_count(value.call(:input)),
        output: normalized_count(value.call(:output)),
        cached: normalized_count(value.call(:cached)),
        cache_read: normalized_count(value.call(:cache_read)),
        cache_write: normalized_count(value.call(:cache_write)),
        reasoning: normalized_count(value.call(:reasoning)),
        input_includes_cache_read: normalized_boolean(value.call(:input_includes_cache_read)),
        input_includes_cache_write: normalized_boolean(value.call(:input_includes_cache_write)),
        output_includes_reasoning: normalized_boolean(value.call(:output_includes_reasoning)),
        model: value.call(:model)&.to_s&.dup&.freeze,
        # Carried as a float: this is money, and normalized_count would round
        # a fraction-of-a-cent charge to zero.
        provider_reported_cost: normalized_cost(value.call(:provider_reported_cost))
      }.freeze
    end
    private_class_method :normalize_usage

    def normalized_cost(value)
      return nil unless value.is_a?(Numeric)

      cost = value.to_f
      cost if cost >= 0 && cost.finite?
    end
    private_class_method :normalized_cost

    def normalized_count(value)
      value.nil? ? nil : [ value.to_i, 0 ].max
    end
    private_class_method :normalized_count

    def normalized_boolean(value)
      value if value == true || value == false
    end
    private_class_method :normalized_boolean

    def unsupported!(profile, capability, diagnostic)
      evidence = unsupported_evidence(profile, capability, diagnostic)
      raise UnsupportedCapability.new(
        evidence.diagnostic,
        evidence: evidence
      )
    end
    private_class_method :unsupported!

    def compilation_error!(profile, error)
      evidence = unsupported_evidence(profile, :compilation, error)
      raise CompilationError.new(
        "agent invocation compilation failed: #{evidence.diagnostic}",
        evidence: evidence
      ), cause: error
    end
    private_class_method :compilation_error!
  end
end
