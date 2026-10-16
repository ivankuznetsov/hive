require "test_helper"
require "hive/model_unsupported"

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
end
