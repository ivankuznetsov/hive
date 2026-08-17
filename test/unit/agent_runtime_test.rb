require "test_helper"
require "hive/agent_runtime"
require "hive/agent_profiles"

class AgentRuntimeTest < Minitest::Test
  FailingProbeProfile = Struct.new(:name, :launcher_identity, :error, keyword_init: true) do
    def check_version!
      raise error
    end

    def preflight!
      nil
    end
  end

  SuccessfulProbeProfile = Struct.new(:name, :launcher_identity, keyword_init: true) do
    def check_version!
      "1.2.3"
    end

    def preflight!
      nil
    end
  end

  FailingCapabilityProfile = Struct.new(:name, :launcher_identity, :error, keyword_init: true) do
    def require_cli_capability!(_name)
      raise error
    end
  end

  class CapabilityCompileProfile
    def initialize(delegate, arguments:)
      @delegate = delegate
      @arguments = arguments
    end

    def require_cli_capability!(_name)
      @arguments
    end

    def method_missing(name, ...)
      return @delegate.public_send(name, ...) if @delegate.respond_to?(name)

      super
    end

    def respond_to_missing?(name, include_private = false)
      @delegate.respond_to?(name, include_private) || super
    end
  end

  class RoutingBlindProfile
    def initialize(delegate)
      @delegate = delegate
    end

    def method_missing(name, ...)
      return @delegate.public_send(name, ...) if @delegate.respond_to?(name)

      super
    end

    def respond_to_missing?(name, include_private = false)
      return false if name == :validate_routing_arguments!

      @delegate.respond_to?(name, include_private) || super
    end
  end

  FailingUsageProfile = Struct.new(:name, :launcher_identity, keyword_init: true) do
    def extract_usage_event(_event)
      raise "invalid usage payload"
    end
  end

  LegacyUsageProfile = Struct.new(
    :name, :launcher_identity, :usage, keyword_init: true
  ) do
    def extract_usage_event(_event)
      usage
    end
  end

  RuntimeProfileAdapter = Struct.new(
    :name, :launcher_identity, :runtime_profile, keyword_init: true
  )

  FailingErrorProfile = Struct.new(:name, :launcher_identity, keyword_init: true) do
    def extract_error_event(_event)
      raise "unreadable provider error payload"
    end
  end

  def test_existing_custom_profile_constructor_compiles_without_new_keywords
    profile = custom_profile
    request = Hive::AgentRuntime::Request.new(profile: profile, prompt: "work")

    invocation = Hive::AgentRuntime.compile(request)

    assert_equal [ "custom-agent", "-p", "work" ], invocation.argv
    assert_nil invocation.stdin_data
    assert_equal "AgentProfile/v1:custom", invocation.launcher_identity
    assert_predicate request, :frozen?
    assert_predicate request.add_dirs, :frozen?
    assert_predicate invocation, :frozen?
    assert_predicate invocation.argv, :frozen?
  end

  def test_existing_claude_profile_preserves_legacy_tool_scope_without_new_keywords
    profile = custom_profile(name: :claude)

    invocation = compile(
      profile,
      allowed_tools: [ "Read" ],
      disallowed_tools: [ "Write" ]
    )

    assert_includes invocation.argv, "--allowedTools"
    assert_includes invocation.argv, "--disallowedTools"

    opted_out = compile(
      custom_profile(name: :claude, tool_scope_flags: {}),
      allowed_tools: [ "Read" ],
      disallowed_tools: [ "Write" ]
    )
    refute_includes opted_out.argv, "--allowedTools"
    refute_includes opted_out.argv, "--disallowedTools"
  end

  def test_compile_rejects_non_request_with_typed_compilation_evidence
    error = assert_raises(Hive::AgentRuntime::CompilationError) do
      Hive::AgentRuntime.compile("not a request")
    end

    assert_evidence error, :compilation
    assert_equal :unknown, error.evidence.provider
  end

  def test_compile_rejects_profile_without_package_runtime
    profile = Struct.new(:name, :headless_supported).new(:custom, true)

    error = assert_raises(Hive::AgentRuntime::CompilationError) do
      compile(profile)
    end

    assert_match(/has no agent-cli-runtime profile/, error.message)
  end

  def test_compile_wraps_package_runtime_errors
    runtime_class = Class.new(AgentCliRuntime::Profile) do
      def permission_flags(_permission_mode = nil)
        raise AgentCliRuntime::Error, "synthetic package compilation failure"
      end
    end
    runtime = runtime_class.new(
      name: :custom,
      bin_default: "custom-agent",
      headless_flag: "-p",
      version_flag: "--version"
    )

    error = assert_raises(Hive::AgentRuntime::CompilationError) do
      compile(runtime)
    end

    assert_match(/synthetic package compilation failure/, error.message)
  end

  def test_typed_routing_rejects_legacy_identity_channels
    profile = Hive::AgentProfiles.lookup(:codex)
    routing = profile.routing_arguments(
      Hive::ModelRouting.resolve(
        models: { "plan" => { "model" => "gpt-5.6-sol" } },
        stage: "plan",
        provider: :codex
      )
    )

    error = assert_raises(Hive::AgentRuntime::CompilationError) do
      compile(
        profile,
        routing_arguments: routing,
        identity_arguments: [ "--model", "legacy-model" ]
      )
    end

    assert_includes error.message, "cannot be combined"
  end

  def test_typed_routing_rejects_profiles_without_the_validation_contract
    delegate = Hive::AgentProfiles.lookup(:codex)
    routing = delegate.routing_arguments(
      Hive::ModelRouting.resolve(
        models: { "plan" => { "model" => "gpt-5.6-sol" } },
        stage: "plan",
        provider: :codex
      )
    )

    error = assert_raises(Hive::AgentRuntime::UnsupportedCapability) do
      compile(RoutingBlindProfile.new(delegate), routing_arguments: routing)
    end

    assert_evidence error, :model_routing
    assert_match(/does not support model routing/, error.message)
  end

  def test_builtin_prompt_transports_preserve_argv_and_stdin
    claude = Hive::AgentProfiles.lookup(:claude)
    codex = Hive::AgentProfiles.lookup(:codex)
    pi = Hive::AgentProfiles.lookup(:pi)
    grok = Hive::AgentProfiles.lookup(:grok)

    claude_call = compile(
      claude,
      add_dirs: [ "/workspace/extra" ],
      allowed_tools: [ "Read" ],
      disallowed_tools: [ "Write" ],
      max_budget_usd: 2
    )
    assert_equal [
      claude.bin, "-p", "--dangerously-skip-permissions",
      "--add-dir", "/workspace/extra",
      "--allowedTools", "Read", "--disallowedTools", "Write",
      "--max-budget-usd", "2",
      *claude.output_format_flags, "do work"
    ], claude_call.argv
    assert_nil claude_call.stdin_data

    codex_call = compile(codex, add_dirs: [ "/workspace/extra" ], max_budget_usd: 2)
    assert_equal [
      codex.bin, "exec", "--dangerously-bypass-approvals-and-sandbox",
      "--add-dir", "/workspace/extra", *codex.output_format_flags, "-"
    ], codex_call.argv
    assert_equal "do work", codex_call.stdin_data

    pi_call = compile(pi, add_dirs: [ "/workspace/extra" ], max_budget_usd: 2)
    assert_equal [ pi.bin, "-p", *pi.output_format_flags, "do work" ], pi_call.argv
    assert_nil pi_call.stdin_data
    directory_evidence = pi_call.capability_evidence.find { |item| item.capability == :add_directory }
    assert_equal false, directory_evidence.supported

    grok_call = compile(grok, max_budget_usd: 2)
    assert_equal [
      grok.bin, "-p", "do work", "--always-approve", *grok.output_format_flags
    ], grok_call.argv
    assert_nil grok_call.stdin_data
  end

  def test_plain_text_consumer_can_omit_provider_output_flags
    invocation = compile(
      Hive::AgentProfiles.lookup(:codex),
      include_output_format: false
    )

    refute_includes invocation.argv, "--json"
    assert_equal "-", invocation.argv.last
    assert_equal "do work", invocation.stdin_data
  end

  def test_supported_model_and_effort_compile_as_discrete_native_arguments
    invocation = compile(
      Hive::AgentProfiles.lookup(:codex),
      model: "gpt-5.6-terra",
      effort: "medium"
    )

    assert_includes invocation.argv, "gpt-5.6-terra"
    assert_includes invocation.argv, "model_reasoning_effort=medium"
    assert invocation.capability_evidence.any? { |item| item.capability == :model && item.supported }
    assert invocation.capability_evidence.any? { |item| item.capability == :effort && item.supported }
  end

  def test_supported_named_capability_compiles_arguments_and_evidence
    profile = CapabilityCompileProfile.new(
      custom_profile,
      arguments: [ "--safe-mode" ]
    )

    invocation = compile(profile, capabilities: [ :safe_mode ])

    assert_includes invocation.argv, "--safe-mode"
    evidence = invocation.capability_evidence.find { |item| item.capability == :safe_mode }
    assert_equal true, evidence.supported
    assert_equal [ "--safe-mode" ], evidence.arguments
  end

  def test_trusted_policy_arguments_decorate_the_compiled_invocation
    invocation = compile(
      custom_profile,
      permission_arguments: [],
      trusted_cli_arguments: [ "--settings", "/trusted/settings.json" ],
      executable: "/trusted/custom-agent",
      command_prefix: [ "/usr/bin/sandbox", "--" ]
    )

    assert_equal(
      [
        "/usr/bin/sandbox", "--", "/trusted/custom-agent",
        "-p", "--settings", "/trusted/settings.json", "do work"
      ],
      invocation.argv
    )
  end

  def test_unsupported_headless_and_permission_modes_fail_with_typed_evidence
    no_headless = custom_profile(headless_supported: false)
    error = assert_raises(Hive::AgentRuntime::UnsupportedCapability) do
      compile(no_headless)
    end
    assert_evidence error, :headless

    %w[read-only workspace-write].each do |mode|
      error = assert_raises(Hive::AgentRuntime::UnsupportedCapability) do
        compile(custom_profile, permission_mode: mode)
      end
      assert_evidence error, mode.tr("-", "_").to_sym
    end
  end

  def test_required_directory_model_effort_and_named_capability_fail_closed
    error = assert_raises(Hive::AgentRuntime::UnsupportedCapability) do
      compile(Hive::AgentProfiles.lookup(:pi), add_dirs: [ "/extra" ], require_add_dirs: true)
    end
    assert_evidence error, :add_directory

    error = assert_raises(Hive::AgentRuntime::UnsupportedCapability) do
      compile(custom_profile, model: "provider/model")
    end
    assert_evidence error, :model

    error = assert_raises(Hive::AgentRuntime::UnsupportedCapability) do
      compile(Hive::AgentProfiles.lookup(:pi), model: "provider/model", effort: "high")
    end
    assert_evidence error, :effort

    error = assert_raises(Hive::AgentRuntime::UnsupportedCapability) do
      compile(custom_profile, effort: "high")
    end
    assert_evidence error, :effort

    error = assert_raises(Hive::AgentRuntime::UnsupportedCapability) do
      compile(custom_profile, capabilities: [ :safe_mode ])
    end
    assert_evidence error, :safe_mode
  end

  def test_probe_failure_returns_bounded_redacted_diagnostic
    secret = "sk-ant-#{'x' * 40}"
    profile = FailingProbeProfile.new(
      name: :custom,
      launcher_identity: "custom/v1",
      error: Hive::AgentError.new("#{secret} #{'detail ' * 200}")
    )

    error = assert_raises(Hive::AgentRuntime::ProbeError) do
      Hive::AgentRuntime.prepare!(profile)
    end

    assert_evidence error, :probe
    refute_includes error.evidence.diagnostic, secret
    assert_includes error.evidence.diagnostic, "[REDACTED:anthropic_api_key]"
    assert_operator error.evidence.diagnostic.bytesize, :<=, Hive::AgentRuntime::DIAGNOSTIC_BYTES
  end

  def test_successful_probe_returns_immutable_value_contract
    result = Hive::AgentRuntime.prepare!(
      SuccessfulProbeProfile.new(name: :custom, launcher_identity: "custom/v2")
    )

    assert_instance_of Hive::AgentRuntime::ProbeResult, result
    assert_equal :custom, result.provider
    assert_equal "custom/v2", result.launcher_identity
    assert_equal "1.2.3", result.version
    assert_predicate result, :frozen?
    assert_predicate result.capability_evidence, :frozen?
    assert_equal %i[headless version preflight], result.capability_evidence.map(&:capability)
    assert result.capability_evidence.all?(&:supported)
  end

  def test_prepare_uses_package_probe_for_adapter_without_hive_version_method
    runtime = AgentCliRuntime::Profile.new(
      name: :custom,
      bin_default: File.expand_path("../fixtures/fake-claude", __dir__),
      headless_flag: "-p",
      version_flag: "--version"
    )
    adapter = RuntimeProfileAdapter.new(
      name: :custom,
      launcher_identity: "adapter/v1",
      runtime_profile: runtime
    )

    result = Hive::AgentRuntime.prepare!(adapter)

    assert_equal "2.1.118", result.version
    assert_equal "adapter/v1", result.launcher_identity
  end

  def test_named_capability_failure_returns_bounded_redacted_diagnostic
    secret = "sk-#{'z' * 40}"
    profile = FailingCapabilityProfile.new(
      name: :custom,
      launcher_identity: "custom/v1",
      error: Hive::AgentError.new("#{secret} #{'detail ' * 200}")
    )

    error = assert_raises(Hive::AgentRuntime::UnsupportedCapability) do
      Hive::AgentRuntime.require_capability!(profile, :safe_mode)
    end

    assert_evidence error, :safe_mode
    refute_includes error.evidence.diagnostic, secret
    assert_includes error.evidence.diagnostic, "[REDACTED:openai_api_key]"
    assert_operator error.evidence.diagnostic.bytesize, :<=, Hive::AgentRuntime::DIAGNOSTIC_BYTES
  end

  def test_prepare_and_capability_preserve_existing_typed_runtime_errors
    evidence = Hive::AgentRuntime::CapabilityEvidence.new(
      capability: :synthetic,
      supported: false,
      provider: :custom,
      launcher_identity: "custom/v1",
      diagnostic: "already typed"
    )
    probe_error = Hive::AgentRuntime::ProbeError.new("probe", evidence: evidence)
    capability_error = Hive::AgentRuntime::UnsupportedCapability.new(
      "capability", evidence: evidence
    )

    probe_profile = FailingProbeProfile.new(
      name: :custom, launcher_identity: "custom/v1", error: probe_error
    )
    capability_profile = FailingCapabilityProfile.new(
      name: :custom, launcher_identity: "custom/v1", error: capability_error
    )

    assert_same probe_error, assert_raises(Hive::AgentRuntime::ProbeError) {
      Hive::AgentRuntime.prepare!(probe_profile)
    }
    assert_same capability_error, assert_raises(Hive::AgentRuntime::UnsupportedCapability) {
      Hive::AgentRuntime.require_capability!(capability_profile, :synthetic)
    }
  end

  def test_observe_normalizes_status_and_usage_without_mutating_legacy_result
    profile = custom_profile
    result = {
      exit_code: 0,
      timed_out: false,
      status: "ok",
      usage: { "input" => -3, output: 9, cached: 2, model: :small },
      final_message: "done",
      error_message: "api_key=#{'a' * 30}"
    }
    original = Marshal.load(Marshal.dump(result))

    observation = Hive::AgentRuntime.observe(profile, result)

    assert_equal original, result
    assert_equal :ok, observation.status
    assert_equal(
      {
        input: 0, output: 9, cached: 2, cache_read: nil,
        cache_write: nil, reasoning: nil, input_includes_cache_read: nil,
        input_includes_cache_write: nil, output_includes_reasoning: nil,
        model: "small"
      },
      observation.usage
    )
    assert_includes observation.diagnostic, "[REDACTED:generic_api_key]"
  end

  def test_legacy_observation_fallback_normalizes_hashes_and_non_hashes
    profile = LegacyUsageProfile.new(
      name: :legacy, launcher_identity: "legacy/v1", usage: nil
    )
    result = {
      exit_code: 3,
      timed_out: true,
      status: "failed",
      usage: { "input" => -1, "output" => 2, "cached" => 3, "model" => :legacy },
      final_message: "stopped",
      limit_text: "api_key=#{'b' * 30}",
      provider_signal: "limit"
    }

    observation = Hive::AgentRuntime.observe(profile, result)

    assert_equal :failed, observation.status
    assert_equal(
      {
        input: 0, output: 2, cached: 3, cache_read: nil,
        cache_write: nil, reasoning: nil, input_includes_cache_read: nil,
        input_includes_cache_write: nil, output_includes_reasoning: nil,
        model: "legacy"
      },
      observation.usage
    )
    assert_includes observation.diagnostic, "[REDACTED:generic_api_key]"
    assert_nil Hive::AgentRuntime.observe(profile, nil).usage
  end

  def test_usage_extraction_normalizes_profile_event
    profile = custom_profile(
      usage_extractor: ->(_event) {
        { "input" => 4, output: 5, cached: -1, model: "provider/model" }
      }
    )

    assert_equal(
      {
        input: 4, output: 5, cached: 0, cache_read: nil,
        cache_write: nil, reasoning: nil, input_includes_cache_read: nil,
        input_includes_cache_write: nil, output_includes_reasoning: nil,
        model: "provider/model"
      },
      Hive::AgentRuntime.extract_usage(profile, { "type" => "usage" })
    )
  end

  def test_usage_extraction_returns_nil_when_profile_rejects_event
    profile = FailingUsageProfile.new(
      name: :custom,
      launcher_identity: "custom/v1"
    )

    assert_nil Hive::AgentRuntime.extract_usage(profile, { "type" => "usage" })
  end

  def test_legacy_usage_extraction_rejects_non_hash_payload
    profile = LegacyUsageProfile.new(
      name: :legacy, launcher_identity: "legacy/v1", usage: "not usage"
    )

    assert_nil Hive::AgentRuntime.extract_usage(profile, { "type" => "usage" })
  end

  def test_extracts_a_refused_pi_turn_as_a_provider_error
    error = Hive::AgentRuntime.extract_provider_error(
      Hive::AgentProfiles.lookup(:pi), PI_REFUSED_TURN
    )

    refute_nil error, "a refused pi turn must reach Hive as a provider error"
    assert_equal :pi, error[:provider]
    assert_equal 402, error[:status_code]
    assert_includes error[:message], "Prompt tokens limit exceeded"
  end

  # A profile that cannot read its own error shape must not take the run down
  # with it: provider-error detection is an enrichment step, so a raising
  # extractor degrades to "no provider error" and the normal exit-code path
  # still classifies the run.
  def test_provider_error_extraction_returns_nil_when_the_profile_raises
    profile = RuntimeProfileAdapter.new(
      name: :custom,
      launcher_identity: "custom/v1",
      runtime_profile: FailingErrorProfile.new(
        name: :custom, launcher_identity: "custom/v1"
      )
    )

    assert_nil Hive::AgentRuntime.extract_provider_error(
      profile, { "type" => "error", "message" => "429 slow down" }
    )
  end

  def test_completed_pi_turn_is_not_a_provider_error
    event = {
      "type" => "message_end",
      "message" => { "stopReason" => "stop", "provider" => "openrouter" }
    }

    assert_nil Hive::AgentRuntime.extract_provider_error(
      Hive::AgentProfiles.lookup(:pi), event
    )
  end

  private

  def compile(profile, **kwargs)
    Hive::AgentRuntime.compile(
      Hive::AgentRuntime::Request.new(
        profile: profile,
        prompt: "do work",
        **kwargs
      )
    )
  end

  def custom_profile(**overrides)
    Hive::AgentProfile.new(
      name: :custom,
      bin_default: "custom-agent",
      headless_flag: "-p",
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      **overrides
    )
  end

  def assert_evidence(error, capability)
    assert_instance_of Hive::AgentRuntime::CapabilityEvidence, error.evidence
    assert_equal capability, error.evidence.capability
    assert_equal false, error.evidence.supported
    assert_equal :custom, error.evidence.provider if error.evidence.provider == :custom
  end

  # A pi turn that OpenRouter refused for spend. pi leaves the envelope type
  # alone and reports the refusal through stopReason/errorMessage, then exits
  # zero — so this seam is the only place the failure is visible.
  PI_REFUSED_TURN = {
    "type" => "message_start",
    "message" => {
      "role" => "assistant",
      "content" => [],
      "provider" => "openrouter",
      "model" => "deepseek/deepseek-v4-pro",
      "stopReason" => "error",
      "errorMessage" =>
        "402: {\"message\":\"Prompt tokens limit exceeded: 25770 > 8471.\",\"code\":402}"
    }
  }.freeze
end
