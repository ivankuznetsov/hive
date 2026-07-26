require_relative "test_helper"

class AgentCliRuntimeRuntimeTest < Minitest::Test
  def test_builtin_provider_order_and_profiles_are_immutable
    assert_equal %i[claude codex pi grok], AgentCliRuntime::Profiles.names
    assert_predicate AgentCliRuntime::Profiles.names, :frozen?
    assert AgentCliRuntime::Profiles.names.all? do |name|
      AgentCliRuntime::Profiles.fetch(name).frozen?
    end
  end

  def test_compile_preserves_each_builtin_prompt_transport
    assert_equal [
      "claude", "-p", "--dangerously-skip-permissions",
      "--output-format", "stream-json", "--include-partial-messages",
      "--verbose", "--no-session-persistence", "hello"
    ], compile(:claude).argv

    codex = compile(:codex)
    assert_equal [
      "codex", "exec", "--dangerously-bypass-approvals-and-sandbox",
      "--json", "-"
    ], codex.argv
    assert_equal "hello", codex.stdin_data

    assert_equal [
      "pi", "-p", "--mode", "json", "--no-session", "hello"
    ], compile(:pi).argv

    assert_equal [
      "grok", "-p", "hello", "--always-approve",
      "--output-format", "streaming-json"
    ], compile(:grok).argv
  end

  def test_compile_translates_models_effort_directories_and_tool_scope
    invocation = compile(
      :claude,
      model: "sonnet",
      effort: "high",
      add_dirs: [ "/tmp/work" ],
      allowed_tools: [ "Read", "Read", "" ],
      disallowed_tools: [ "Write" ]
    )

    assert_includes invocation.argv, "--model"
    assert_includes invocation.argv, "sonnet"
    assert_includes invocation.argv, "--effort"
    assert_includes invocation.argv, "high"
    assert_includes invocation.argv, "--add-dir"
    assert_includes invocation.argv, "/tmp/work"
    assert_includes invocation.argv, "--allowedTools"
    assert_includes invocation.argv, "Read"
    assert_includes invocation.argv, "--disallowedTools"
    assert_includes invocation.argv, "Write"
  end

  def test_compile_fails_closed_for_required_unsupported_capability
    error = assert_raises(AgentCliRuntime::UnsupportedCapability) do
      compile(:codex, allowed_tools: [ "Read" ])
    end

    assert_equal :allowed_tools, error.evidence.capability
    refute error.evidence.supported
    assert_equal :codex, error.evidence.provider
  end

  def test_compile_returns_typed_unsupported_directory_evidence_when_optional
    invocation = compile(:pi, add_dirs: [ "/tmp/work" ])
    evidence = invocation.capability_evidence.find do |item|
      item.capability == :add_directory
    end

    refute evidence.supported
    assert_match(/intentionally omitted/, evidence.diagnostic)
    refute_includes invocation.argv, "/tmp/work"
  end

  def test_usage_extractors_normalize_provider_streams
    claude = AgentCliRuntime.extract_usage(
      :claude,
      "type" => "result",
      "usage" => {
        "input_tokens" => 12,
        "output_tokens" => 3,
        "cache_read_input_tokens" => 5
      },
      "model" => "claude-sonnet"
    )
    codex = AgentCliRuntime.extract_usage(
      :codex,
      "type" => "turn.completed",
      "usage" => { "input_tokens" => 7, "output_tokens" => 4 }
    )
    pi = AgentCliRuntime.extract_usage(
      :pi,
      "type" => "result",
      "usage" => { "promptTokens" => 8, "completionTokens" => 2 }
    )
    grok = AgentCliRuntime.extract_usage(:grok, "type" => "end")

    assert_equal({ input: 12, output: 3, cached: 5, model: "claude-sonnet" }, claude)
    assert_equal({ input: 7, output: 4, cached: 0, model: nil }, codex)
    assert_equal({ input: 8, output: 2, cached: 0, model: nil }, pi)
    assert_nil grok
    assert_predicate claude, :frozen?
  end

  def test_terminal_events_without_usage_do_not_invent_zero_token_usage
    {
      claude: { "type" => "result" },
      codex: { "type" => "turn.completed" },
      pi: { "type" => "result" },
      grok: { "type" => "end" }
    }.each do |provider, event|
      assert_nil AgentCliRuntime.extract_usage(provider, event), provider
    end
  end

  def test_facade_preserves_unknown_provider_errors
    request = AgentCliRuntime::Request.new(
      profile: :unknown,
      prompt: "hello"
    )

    assert_raises(AgentCliRuntime::UnknownProvider) do
      AgentCliRuntime.compile(request)
    end
    assert_raises(AgentCliRuntime::UnknownProvider) do
      AgentCliRuntime.probe(:unknown)
    end
    assert_raises(AgentCliRuntime::UnknownProvider) do
      AgentCliRuntime.prepare!(:unknown)
    end
    assert_raises(AgentCliRuntime::UnknownProvider) do
      AgentCliRuntime.require_capability!(:unknown, :safe_mode)
    end
    assert_raises(AgentCliRuntime::UnknownProvider) do
      AgentCliRuntime.extract_usage(:unknown, {})
    end
    assert_raises(AgentCliRuntime::UnknownProvider) do
      AgentCliRuntime.observe(:unknown, {})
    end
  end

  def test_grok_api_key_ignores_unused_relative_auth_paths
    env = {
      "XAI_API_KEY" => "configured",
      "GROK_AUTH_PATH" => "relative/auth.json",
      "GROK_HOME" => "relative/home"
    }

    auth = AgentCliRuntime::Profiles.fetch(:grok).auth_configuration(env:)

    assert auth.configured?
    assert_equal "environment", auth.source
    assert_nil auth.diagnostic
  end

  def test_diagnostics_are_bounded_and_redacted
    profile = AgentCliRuntime::Profile.new(
      name: :custom,
      bin_default: Gem.ruby,
      headless_flag: "-p",
      version_flag: "--version",
      auth_configuration_probe: ->(**) {
        raise "token sk-#{'z' * 80} #{'x' * 1_000}"
      }
    )

    result = AgentCliRuntime.probe(profile)

    refute result.ready
    refute_includes result.diagnostic, "sk-"
    assert_includes result.diagnostic, "[REDACTED:openai_api_key]"
    assert_operator result.diagnostic.bytesize, :<=, AgentCliRuntime::DIAGNOSTIC_BYTES
  end

  private

  def compile(provider, **options)
    AgentCliRuntime.compile(
      AgentCliRuntime::Request.new(
        profile: AgentCliRuntime::Profiles.fetch(provider),
        prompt: "hello",
        **options
      )
    )
  end
end
