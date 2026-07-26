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

  FailingUsageProfile = Struct.new(:name, :launcher_identity, keyword_init: true) do
    def extract_usage_event(_event)
      raise "invalid usage payload"
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

  def test_compile_rejects_non_request_with_typed_compilation_evidence
    error = assert_raises(Hive::AgentRuntime::CompilationError) do
      Hive::AgentRuntime.compile("not a request")
    end

    assert_evidence error, :compilation
    assert_equal :unknown, error.evidence.provider
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
    assert_equal({ input: 0, output: 9, cached: 2, model: "small" }, observation.usage)
    assert_includes observation.diagnostic, "[REDACTED:generic_api_key]"
  end

  def test_usage_extraction_normalizes_profile_event
    profile = custom_profile(
      usage_extractor: ->(_event) {
        { "input" => 4, output: 5, cached: -1, model: "provider/model" }
      }
    )

    assert_equal(
      { input: 4, output: 5, cached: 0, model: "provider/model" },
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
end
