require_relative "test_helper"

class AgentCliRuntimeErrorExtractorsTest < Minitest::Test
  # Verbatim envelope from a pi run whose OpenRouter key hit its ceiling: the
  # type stays "message_start", content is empty, and the refusal lives in
  # stopReason/errorMessage while the process still exits zero.
  PI_REFUSAL = JSON.parse(
    File.read(File.join(__dir__, "fixtures", "pi_provider_limit.json"))
  ).freeze

  PI_SUCCESS = {
    "type" => "message_end",
    "message" => {
      "role" => "assistant",
      "provider" => "openrouter",
      "model" => "deepseek/deepseek-v4-pro",
      "stopReason" => "stop"
    }
  }.freeze

  PI_OUTPUT_TRUNCATED = {
    "type" => "message_end",
    "message" => {
      "role" => "assistant",
      "provider" => "openrouter",
      "model" => "deepseek/deepseek-v4-pro",
      "usage" => { "input" => 8_079, "output" => 8_192 },
      "stopReason" => "length",
      "rawStopReason" => "length"
    }
  }.freeze

  def test_pi_refusal_is_extracted_with_its_status_code
    error = AgentCliRuntime.extract_provider_error(:pi, PI_REFUSAL)

    refute_nil error, "a stopReason=error turn must surface as a provider error"
    assert_equal :provider_limit, error[:kind]
    assert_equal :pi, error[:provider]
    assert_equal 402, error[:status_code]
    assert_includes error[:message], "Prompt tokens limit exceeded"
    assert_predicate error, :frozen?
  end

  def test_pi_completed_turn_is_not_an_error
    assert_nil AgentCliRuntime.extract_provider_error(:pi, PI_SUCCESS)
  end

  def test_pi_output_truncation_is_a_typed_incomplete_turn
    error = AgentCliRuntime.extract_provider_error(:pi, PI_OUTPUT_TRUNCATED)

    refute_nil error, "stopReason=length must not read as a successful Pi turn"
    assert_equal :model_output_limit, error[:kind]
    assert_equal :pi, error[:provider]
    assert_nil error[:status_code]
    assert_equal "model response reached its maximum output tokens", error[:message]
  end

  def test_pi_refusal_without_a_status_code_still_reports_the_message
    event = {
      "type" => "message_end",
      "message" => { "stopReason" => "error", "errorMessage" => "upstream refused" }
    }
    error = AgentCliRuntime.extract_provider_error(:pi, event)

    assert_equal :provider_error, error[:kind]
    assert_equal "upstream refused", error[:message]
    assert_nil error[:status_code]
  end

  def test_default_extractor_reads_dedicated_error_events
    error = AgentCliRuntime.extract_provider_error(
      :codex, { "type" => "error", "message" => "429: rate limit reached" }
    )

    assert_equal :rate_limited, error[:kind]
    assert_equal 429, error[:status_code]
    assert_equal :codex, error[:provider]
  end

  def test_default_extractor_reads_failed_results
    error = AgentCliRuntime.extract_provider_error(
      :claude,
      { "type" => "result", "is_error" => true, "error" => { "message" => "quota exhausted" } }
    )

    assert_equal :provider_limit, error[:kind]
    assert_equal "quota exhausted", error[:message]
  end

  def test_opencode_extractor_reads_nested_provider_rate_limit
    event = {
      "type" => "error",
      "sessionID" => "ses_rate_limit",
      "error" => {
        "name" => "APIError",
        "data" => {
          "message" => "[Stealth] stealth/ox-alpha is temporarily rate-limited upstream. Please retry shortly."
        }
      }
    }

    error = AgentCliRuntime.extract_provider_error(:opencode, event)

    assert_equal :rate_limited, error[:kind]
    assert_equal :opencode, error[:provider]
    assert_nil error[:status_code]
    assert_includes error[:message], "temporarily rate-limited upstream"
  end

  def test_ordinary_events_are_not_errors
    [
      { "type" => "result", "is_error" => false, "message" => "done" },
      { "type" => "message_start", "message" => { "stopReason" => "stop" } },
      { "type" => "stream_event" },
      "not-a-hash",
      nil
    ].each do |event|
      assert_nil AgentCliRuntime.extract_provider_error(:pi, event),
                 "#{event.inspect} must not read as a provider error"
    end
  end

  def test_extraction_never_raises_on_a_hostile_extractor
    profile = AgentCliRuntime::Profile.new(
      name: :exploding, bin_default: "x", version_flag: "--version",
      headless_flag: "-p", error_extractor: ->(_event) { raise "boom" }
    )

    assert_nil profile.extract_error_event({ "type" => "error" })
  end

  def test_secrets_in_provider_text_are_redacted
    event = {
      "type" => "error",
      "message" => "401: bad key sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH"
    }
    error = AgentCliRuntime.extract_provider_error(:claude, event)

    refute_includes error[:message], "sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH"
  end
end
