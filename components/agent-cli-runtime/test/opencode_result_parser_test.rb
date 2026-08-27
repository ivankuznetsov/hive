require_relative "test_helper"

class AgentCliRuntimeOpenCodeResultParserTest < Minitest::Test
  def test_completed_result_correlates_terminal_message_and_sanitized_export
    parsed = AgentCliRuntime.parse_run(:opencode, stdout: fixture("run-one-step.jsonl"))

    assert_equal "ses_contract_one", parsed.session_id
    assert_equal "msg_assistant_final", parsed.terminal_message_id
    assert_equal "Done.", parsed.final_message
    refute parsed.final_message_truncated
    assert_equal "stop", parsed.terminal_reason
    assert_equal 5, parsed.preliminary_usage.input
    assert_equal 0, parsed.preliminary_usage.cache_write

    outcome = normalize(
      stdout: fixture("run-one-step.jsonl"),
      export: fixture("session-export-matching.json")
    )

    assert_equal :completed, outcome.kind
    assert outcome.completed?
    assert_equal "Done.", outcome.final_message
    refute outcome.final_message_truncated
    assert_equal "anthropic/claude-sonnet-4-5", outcome.identity.requested.to_s
    assert_equal "anthropic/claude-sonnet-4-5", outcome.identity.actual.to_s
    assert_equal :matched, outcome.identity.resolution_status
    assert_equal 5, outcome.usage.input
    assert_equal 2, outcome.usage.output
    assert_equal 2, outcome.usage.cache_read
    assert_equal 0, outcome.usage.cache_write
    assert_equal 0, outcome.usage.reasoning
    assert_equal 0.0, outcome.usage.cost
    assert_equal 0.0, outcome.usage.provider_reported_cost
    assert_includes outcome.usage.to_h, :cost
    refute_includes outcome.usage.to_h, :provider_reported_cost
    assert_equal 2, outcome.usage.cached
    assert_nil outcome.diagnostic
  end

  def test_observed_route_is_not_inferred_from_requested_alias
    outcome = normalize(
      stdout: fixture("run-one-step.jsonl"),
      export: fixture("session-export-fallback.json"),
      requested_route: "requested-alias/sonnet"
    )

    assert_equal :completed, outcome.kind
    assert_equal "requested-alias/sonnet", outcome.identity.requested.to_s
    assert_equal "openrouter/anthropic/claude-sonnet-4", outcome.identity.actual.to_s
    assert_equal :resolved_differently, outcome.identity.resolution_status
    assert_equal 9, outcome.usage.input
    assert_equal 3, outcome.usage.output
    assert_equal 1, outcome.usage.reasoning
    assert_equal 0, outcome.usage.cached
  end

  def test_multi_step_result_selects_only_the_terminal_message
    stdout = fixture("run-multi-step.jsonl")
    parsed = AgentCliRuntime.parse_run(:opencode, stdout:)

    assert_equal "msg_assistant_2", parsed.terminal_message_id
    assert_equal "Final answer.", parsed.final_message
    refute_includes parsed.final_message, "Inspecting."

    export = export_for(
      session_id: parsed.session_id,
      message_id: parsed.terminal_message_id,
      provider: "anthropic",
      model: "claude-sonnet-4-5",
      tokens: {
        "input" => 18, "output" => 7, "reasoning" => 2,
        "cache" => { "read" => 3 }
      }
    )
    outcome = normalize(stdout:, export:)

    assert_equal :completed, outcome.kind
    assert_equal "Final answer.", outcome.final_message
    assert_equal 3, outcome.usage.cache_read
    assert_nil outcome.usage.cache_write
    assert_nil outcome.usage.cached
    assert_nil outcome.usage.cost
  end

  def test_unknown_additive_events_are_summarized_without_retaining_payloads
    stdout = fixture("run-tool-and-unknown.jsonl").sub(
      '"nested":"not retained"',
      '"nested":"api_key=abcdefghijklmnopqrstuvwxyz123456"'
    )
    parsed = AgentCliRuntime.parse_run(:opencode, stdout:)

    assert_equal [ "unknown OpenCode event telemetry_hint" ],
                 parsed.unknown_events
    refute_includes parsed.unknown_events.inspect, "abcdefghijklmnopqrstuvwxyz"

    outcome = normalize(
      stdout:,
      export: export_for(
        session_id: parsed.session_id,
        message_id: parsed.terminal_message_id,
        provider: "anthropic",
        model: "claude-sonnet-4-5",
        tokens: {}
      )
    )
    assert_equal parsed.unknown_events, outcome.unknown_events
  end

  def test_first_unknown_additive_event_binds_the_run_session
    unknown = JSON.generate(
      "type" => "telemetry_hint", "sessionID" => "ses_other", "payload" => {}
    ) + "\n"

    assert_raises(AgentCliRuntime::MalformedOutput) do
      AgentCliRuntime.parse_run(
        :opencode, stdout: unknown + fixture("run-one-step.jsonl")
      )
    end
  end

  def test_timeout_and_cancellation_take_precedence_over_incomplete_output
    malformed = fixture("run-malformed-json.jsonl")

    timed_out = normalize(
      stdout: malformed,
      termination: AgentCliRuntime::TerminationEvidence.new(
        exit_code: nil, timed_out: true
      )
    )
    cancelled = normalize(
      stdout: malformed,
      termination: AgentCliRuntime::TerminationEvidence.new(
        exit_code: nil, cancelled: true, signal: "TERM"
      )
    )

    assert_equal :timed_out, timed_out.kind
    assert_equal :cancelled, cancelled.kind
    assert_nil timed_out.final_message
    assert_nil cancelled.final_message
  end

  def test_nonzero_exit_classification_precedes_strict_output_validation
    auth = normalize(
      stdout: fixture("run-auth-error.jsonl"),
      stderr: "provider rejected credential sk-#{'a' * 40}",
      termination: AgentCliRuntime::TerminationEvidence.new(exit_code: 1)
    )
    config = normalize(
      stdout: fixture("run-configuration-error.jsonl"),
      termination: AgentCliRuntime::TerminationEvidence.new(exit_code: 1)
    )
    upstream_timeout = normalize(
      stdout: fixture("run-upstream-timeout-error.jsonl"),
      termination: AgentCliRuntime::TerminationEvidence.new(exit_code: 1)
    )
    cli = normalize(
      stdout: fixture("run-malformed-json.jsonl"),
      stderr: "process failed",
      termination: AgentCliRuntime::TerminationEvidence.new(exit_code: 70)
    )

    assert_equal :authentication_failure, auth.kind
    assert_equal :configuration_failure, config.kind
    assert_equal :timed_out, upstream_timeout.kind
    assert_includes upstream_timeout.diagnostic, "Upstream idle timeout exceeded"
    assert_equal :cli_failure, cli.kind
    refute_includes auth.diagnostic, "sk-"
    assert_includes auth.diagnostic, "[REDACTED:openai_api_key]"

    operational = normalize(
      stdout: "", stderr: "provider rate limit reached for model",
      termination: AgentCliRuntime::TerminationEvidence.new(exit_code: 1)
    )
    assert_equal :cli_failure, operational.kind
  end

  def test_signal_terminated_run_is_a_cli_failure_not_success
    outcome = normalize(
      stdout: fixture("run-one-step.jsonl"), stderr: "terminated",
      termination: AgentCliRuntime::TerminationEvidence.new(
        exit_code: nil, signal: "TERM"
      )
    )

    assert_equal :cli_failure, outcome.kind
    refute outcome.completed?
  end

  def test_zero_exit_rejects_malformed_or_uncorrelated_success_evidence
    malformed_json = normalize(stdout: fixture("run-malformed-json.jsonl"))
    malformed_terminal = normalize(stdout: fixture("run-malformed-terminal.jsonl"))
    missing_export = normalize(stdout: fixture("run-one-step.jsonl"))
    wrong_export = normalize(
      stdout: fixture("run-one-step.jsonl"),
      export: export_for(
        session_id: "ses_other",
        message_id: "msg_assistant_final",
        provider: "anthropic",
        model: "claude-sonnet-4-5",
        tokens: {}
      )
    )

    [ malformed_json, malformed_terminal, missing_export, wrong_export ].each do |outcome|
      assert_equal :malformed_output, outcome.kind
      refute outcome.completed?
      assert_operator outcome.diagnostic.bytesize,
                      :<=, AgentCliRuntime::DIAGNOSTIC_BYTES
    end
  end

  def test_tool_only_terminal_step_can_complete_with_empty_final_text
    empty = fixture("run-one-step.jsonl").sub('"text":"Done."', '"text":""')
    parsed = AgentCliRuntime.parse_run(:opencode, stdout: empty)

    assert_equal "", parsed.final_message

    outcome = normalize(
      stdout: empty,
      export: export_for(
        session_id: parsed.session_id,
        message_id: parsed.terminal_message_id,
        provider: "anthropic",
        model: "claude-sonnet-4-5",
        tokens: {}
      )
    )

    assert outcome.completed?
    assert_equal "", outcome.final_message
  end

  def test_mismatched_sessions_are_malformed
    mismatched = fixture("run-one-step.jsonl").sub(
      '"sessionID":"ses_contract_one","part":{"id":"prt_text_one"',
      '"sessionID":"ses_other","part":{"id":"prt_text_one"'
    )

    assert_raises(AgentCliRuntime::MalformedOutput) do
      AgentCliRuntime.parse_run(:opencode, stdout: mismatched)
    end
  end

  def test_captured_and_retained_output_are_bounded
    long_text = "x" * (AgentCliRuntime::OpenCode::ResultParser::MAX_FINAL_MESSAGE_BYTES + 32)
    stdout = fixture("run-one-step.jsonl").sub("Done.", long_text)
    parsed = AgentCliRuntime.parse_run(:opencode, stdout:)

    assert_equal AgentCliRuntime::OpenCode::ResultParser::MAX_FINAL_MESSAGE_BYTES,
                 parsed.final_message.bytesize
    assert parsed.final_message_truncated

    outcome = normalize(
      stdout: "x" * (AgentCliRuntime::OpenCode::ResultParser::MAX_RUN_BYTES + 1)
    )
    assert_equal :malformed_output, outcome.kind
    assert_operator outcome.diagnostic.bytesize,
                    :<=, AgentCliRuntime::DIAGNOSTIC_BYTES
  end

  def test_inspection_command_is_non_model_and_uses_the_same_overlay
    parsed = AgentCliRuntime.parse_run(:opencode, stdout: fixture("run-one-step.jsonl"))
    prepared = prepared_invocation
    inspection = AgentCliRuntime.prepare_inspection(prepared, parsed)

    assert_equal [ "/usr/bin/opencode", "export", "ses_contract_one", "--sanitize" ],
                 inspection.argv
    assert_nil inspection.stdin_data
    assert_equal({ "XDG_DATA_HOME" => "/private/data" }, inspection.environment)
    assert_equal [ "ANTHROPIC_API_KEY" ], inspection.credential_environment_keys
    assert_equal "secret-canary",
                 inspection.environment_for(
                   env: { "ANTHROPIC_API_KEY" => "secret-canary" }
                 ).fetch("ANTHROPIC_API_KEY")
    refute inspection.argv.any? { |argument| argument.include?("run") }
  end

  def test_strict_parser_is_additive_to_legacy_observation
    observed = AgentCliRuntime.observe(
      :codex,
      exit_code: 0,
      usage: { input: 0, output: 0, cached: 0 }
    )

    assert_equal :codex, observed.provider
    assert_equal 0, observed.usage.fetch(:input)
    assert_raises(AgentCliRuntime::UnsupportedCapability) do
      AgentCliRuntime.parse_run(:codex, stdout: "{}\n")
    end
  end

  private

  def fixture(name)
    File.read(File.expand_path(
      "fixtures/opencode/v1.18.16/#{name}", __dir__
    ))
  end

  def normalize(stdout:, export: nil, stderr: "", requested_route: "anthropic/claude-sonnet-4-5",
                termination: AgentCliRuntime::TerminationEvidence.new(exit_code: 0))
    AgentCliRuntime.normalize(
      :opencode,
      AgentCliRuntime::CapturedResult.new(
        stdout:, stderr:, termination:, inspection_output: export
      ),
      requested_route:
    )
  end

  def export_for(session_id:, message_id:, provider:, model:, tokens:)
    JSON.generate(
      "info" => { "id" => session_id },
      "messages" => [
        {
          "info" => {
            "id" => message_id,
            "sessionID" => session_id,
            "role" => "assistant",
            "providerID" => provider,
            "modelID" => model,
            "tokens" => tokens,
            "finish" => "stop"
          },
          "parts" => []
        }
      ]
    )
  end

  def prepared_invocation
    invocation = AgentCliRuntime::CompiledInvocation.new(
      argv: [ "/usr/bin/opencode", "run", "prompt" ],
      stdin_data: nil,
      provider: :opencode,
      launcher_identity: "opencode-cli/v1",
      capability_evidence: []
    )
    AgentCliRuntime::PreparedInvocation.new(
      invocation:,
      environment: { "XDG_DATA_HOME" => "/private/data" },
      credential_environment_keys: [ "ANTHROPIC_API_KEY" ],
      invocation_root: "/private",
      generated_paths: [ "/private" ],
      configuration_path: "/private/opencode.json",
      requested_route: AgentCliRuntime::Route.parse("anthropic/claude-sonnet-4-5"),
      configuration_source: "inline",
      probe_result: nil,
      cleanup: -> { },
      executable: "/usr/bin/opencode"
    )
  end
end
