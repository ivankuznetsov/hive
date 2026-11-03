require "test_helper"
require "hive/model_unsupported"
require "hive/agent_cli_identity"
require "hive/markers"

class ModelUnsupportedTest < Minitest::Test
  # Exact Codex stream line observed in the field (JSON-escaped inner payload).
  SOL_STREAM_LINE = '{"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":' \
                    '{\"type\":\"invalid_request_error\",\"message\":\"The \'gpt-6-sol\' model is not ' \
                    'supported when using Codex with a ChatGPT account.\"}}"}'.freeze
  SOL_1_MESSAGE = "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.".freeze

  def test_detects_both_real_codex_messages
    assert Hive::ModelUnsupported.detected?(SOL_STREAM_LINE)
    assert Hive::ModelUnsupported.detected?(SOL_1_MESSAGE)
    assert Hive::ModelUnsupported.detected?("codex exited 1\n#{SOL_1_MESSAGE}\n")
  end

  def test_ignores_unrelated_not_supported_text_and_quota_walls
    refute Hive::ModelUnsupported.detected?("This model is not supported by the linter.")
    refute Hive::ModelUnsupported.detected?("You've hit your usage limit. Try again later.")
    refute Hive::ModelUnsupported.detected?(nil)
    refute Hive::ModelUnsupported.detected?("")
  end

  def test_extracts_model_name_from_raw_and_escaped_text
    assert_equal "gpt-6-sol", Hive::ModelUnsupported.model_name(SOL_STREAM_LINE)
    assert_equal "gpt-6.1-sol", Hive::ModelUnsupported.model_name(SOL_1_MESSAGE)
    assert_equal "gpt-6-sol", Hive::ModelUnsupported.model_name(
      %q(The \'gpt-6-sol\' model is not supported when using Codex with a ChatGPT account.)
    )
    assert_nil Hive::ModelUnsupported.model_name("model is not supported when using codex with a chatgpt account")
    formatted = Hive::ModelUnsupported.error_message(SOL_1_MESSAGE, agent: "codex")
    assert_equal "gpt-6.1-sol", Hive::ModelUnsupported.model_name("fix agent failed\n#{formatted}")
  end

  def test_error_message_names_model_agent_and_fix
    message = Hive::ModelUnsupported.error_message(SOL_1_MESSAGE, agent: "codex")

    assert_equal "model unsupported for codex: 'gpt-6.1-sol' is not available to this account; " \
                 "set a supported model for this stage/role in .hive-state/config.yml " \
                 "(models routing), then retry the task", message
    assert_operator message.bytesize, :<=, 200
    assert Hive::ModelUnsupported.detected?(message), "the formatted message must re-classify downstream"
    assert_match(/\Amodel unsupported: the configured model/,
                 Hive::ModelUnsupported.error_message("model is not supported when using codex with a chatgpt account"))
  end

  def test_operator_message_prefers_existing_formatted_line
    formatted = Hive::ModelUnsupported.error_message(SOL_1_MESSAGE, agent: "codex")

    assert_equal formatted, Hive::ModelUnsupported.operator_message("triage agent failed\n#{formatted}")
    assert_equal Hive::ModelUnsupported.error_message(SOL_STREAM_LINE, agent: "codex"),
                 Hive::ModelUnsupported.operator_message(SOL_STREAM_LINE, agent: "codex")
  end

  def test_marker_and_remediation
    assert Hive::ModelUnsupported.marker?("reason" => "model_unsupported")
    assert Hive::ModelUnsupported.marker?(reason: "model_unsupported")
    refute Hive::ModelUnsupported.marker?("reason" => "limits_reached")
    refute Hive::ModelUnsupported.marker?(nil)

    assert_equal "change it", Hive::ModelUnsupported.remediation("message" => "change it")
    assert_match(/rejected the configured model; set a supported model/,
                 Hive::ModelUnsupported.remediation({}))
    assert_match(/\.hive-state\/config\.yml/, Hive::ModelUnsupported.remediation(nil))
  end

  def test_identity_enriches_raw_and_forwarded_diagnoses_without_losing_model
    path = "/home/operator/" + ("long cli 空間/" * 30) + 'codex "selected"'
    identity = Hive::AgentCliIdentity::Value.new(
      profile: "codex", regime: "plain", authority: "child_path", configured: "codex",
      launch_path: path, effective_target: path, version: "0.153.4", version_source: "npm",
      reason: nil, version_reason: nil, sandbox_executable: nil, command_prefix: []
    )
    raw = "#{SOL_1_MESSAGE} API_KEY=abcdefghijklmnopqrstuvwx"
    forwarded = Hive::ModelUnsupported.error_message(raw, agent: "codex")
    [raw, "reviewer failed\n#{forwarded}"].each do |text|
      message = Hive::ModelUnsupported.operator_message(text, agent: "codex", cli_identity: identity,
        diagnostic_reference: "attempt:11111111-1111-1111-1111-111111111111")
      assert_includes message, path
      assert_includes message, "0.153.4"
      assert_includes message, "agents.codex.bin"
      assert_includes message, "agents.codex.min_version"
      assert_includes message, "stale CLI"
      assert_equal "gpt-6.1-sol", Hive::ModelUnsupported.model_name(message)
      refute_includes message, "abcdefghijklmnopqrstuvwx"
      marker = Hive::Markers.build_marker("ERROR", reason: "model_unsupported", message: message)
      attrs = Hive::Markers.current_from_content(marker).attrs
      refute_includes attrs.fetch("message"), path
      assert_includes attrs.fetch("message"), "diagnostic=attempt:11111111-1111-1111-1111-111111111111"
      assert_includes attrs.fetch("message"), "hive task TARGET --log"
      assert_operator Hive::Markers.format_attr(attrs.fetch("message")).bytesize, :<=, 200
      assert_predicate marker, :valid_encoding?
    end
  end

  def test_forwarded_identity_enrichment_retains_the_original_reference_and_command
    identity = Hive::AgentCliIdentity::Value.new(**%i[profile regime authority configured launch_path
      effective_target version version_source reason version_reason sandbox_executable command_prefix].to_h { |key| [key, nil] })
    text = "model unsupported for codex: 'gpt-6-sol' is not available; diagnostic=attempt:original; hive task 43359 --log"
    message = Hive::ModelUnsupported.operator_message(text, cli_identity: identity)
    assert_includes message, "diagnostic=attempt:original"
    assert_includes message, "hive task 43359 --log"
    assert_includes message, "version=unknown (identity_unavailable)"
    assert_includes message, "launch_path=unavailable"
    override = Hive::ModelUnsupported.operator_message(text, cli_identity: identity, diagnostic_reference: "attempt:replacement")
    assert_includes override, "diagnostic=attempt:replacement"
    refute_includes override, "attempt:original"
  end

  def test_marker_serialization_bounds_escaped_multibyte_content_and_redacts_all_attributes
    message = ('空間 <!-- " --> ' * 60) + "API_KEY=abcdefghijklmnopqrstuvwx"
    bounded = Hive::Markers.bounded_message(message, max: 200)
    assert_predicate bounded, :valid_encoding?
    assert bounded.end_with?("…")
    assert_operator Hive::Markers.format_attr(bounded).bytesize, :<=, 200
    marker = Hive::Markers.build_marker("ERROR", reason: "model_unsupported",
      message: SOL_1_MESSAGE, detail: "API_KEY=abcdefghijklmnopqrstuvwx", optional: nil)
    refute_includes marker, "abcdefghijklmnopqrstuvwx"
    assert_includes marker, "[REDACTED:generic_api_key]"
    refute_includes marker, "optional="
    assert_includes Hive::ModelUnsupported.remediation(reason: "model_unsupported", message: "old failure"),
      "identity/version unavailable"
    assert_includes Hive::ModelUnsupported.marker_message(SOL_1_MESSAGE, diagnostic_reference: "invalid/path"),
      "diagnostic=task-log"
    task = Struct.new(:id, :slug).new(nil, "a" * 64)
    compact = Hive::ModelUnsupported.marker_message("The '#{'model' * 20}' model is not supported when using Codex with a ChatGPT account.",
      task: task, agent: "custom-profile", diagnostic_reference: "attempt:11111111-1111-1111-1111-111111111111")
    assert_operator Hive::Markers.format_attr(compact).bytesize, :<=, 200
    assert_includes compact, "hive task #{'a' * 64} --log"
    assert_includes compact, "supported model"
  end

  def test_missing_private_log_does_not_block_the_durable_terminal_diagnosis
    reference = nil
    _, output = capture_io do
      reference = Hive::ModelUnsupported.record_diagnostic(SOL_1_MESSAGE,
        agent: "codex", cli_identity: nil, log_file: "/definitely/missing/agent.log")
    end
    assert_equal "task-log", reference
    assert_includes output, "CLI identity/version unavailable"
    assert_includes output, "agents.codex.bin"
    assert_includes output, "agents.codex.min_version"
    assert_includes output, "supported model"
  end
end
