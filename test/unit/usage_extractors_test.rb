require "test_helper"
require "json"
require "hive/agent_profiles/usage_extractors"

class UsageExtractorsTest < Minitest::Test
  CLAUDE = Hive::AgentProfiles::UsageExtractors::CLAUDE
  CODEX = Hive::AgentProfiles::UsageExtractors::CODEX
  PI = Hive::AgentProfiles::UsageExtractors::PI

  def event(hash)
    JSON.parse(JSON.generate(hash))
  end

  def test_claude_result_with_zero_usage_and_empty_model_usage
    result = CLAUDE.call(event(
      "type" => "result",
      "usage" => {
        "input_tokens" => 0,
        "output_tokens" => 0,
        "cache_read_input_tokens" => 0,
        "cache_creation_input_tokens" => 0
      },
      "modelUsage" => {}
    ))

    assert_equal({ input: 0, output: 0, cached: 0, model: nil }, result)
  end

  def test_claude_result_with_non_zero_usage
    result = CLAUDE.call(event(
      "type" => "result",
      "usage" => {
        "input_tokens" => 123,
        "output_tokens" => 45,
        "cache_read_input_tokens" => 6,
        "cache_creation_input_tokens" => 7
      },
      "modelUsage" => {
        "claude-opus-4-7[1m]" => { "inputTokens" => 123 }
      }
    ))

    assert_equal({ input: 123, output: 45, cached: 13, model: "claude-opus-4-7[1m]" }, result)
  end

  def test_claude_stream_event_extracts_partial_usage
    result = CLAUDE.call(event(
      "type" => "stream_event",
      "event" => {
        "usage" => {
          "input_tokens" => 3,
          "output_tokens" => 2,
          "cache_read_input_tokens" => 1,
          "cache_creation_input_tokens" => 4
        }
      }
    ))

    assert_equal({ input: 3, output: 2, cached: 5, model: nil }, result)
  end

  def test_non_usage_lines_return_nil
    assert_nil CLAUDE.call(event("type" => "system"))
    assert_nil CLAUDE.call(event("type" => "assistant", "message" => { "content" => [] }))
  end

  def test_non_hash_input_returns_nil
    assert_nil CLAUDE.call("not-json")
  end

  def test_codex_usage_shape
    result = CODEX.call(event(
      "type" => "turn.completed",
      "usage" => {
        "input_tokens" => 1000,
        "output_tokens" => 200,
        "cached_input_tokens" => 300,
        "model" => "gpt-5-codex"
      }
    ))

    assert_equal({ input: 1000, output: 200, cached: 300, model: "gpt-5-codex" }, result)
  end

  def test_codex_final_event_without_usage_zero_fills
    result = CODEX.call(event("type" => "turn.completed", "model" => "gpt-5-codex"))

    assert_equal({ input: 0, output: 0, cached: 0, model: "gpt-5-codex" }, result)
  end

  def test_pi_usage_shape
    result = PI.call(event(
      "type" => "result",
      "usage" => {
        "prompt_tokens" => 40,
        "completion_tokens" => 20,
        "prompt_tokens_details" => { "cached_tokens" => 10 }
      },
      "model" => "pi-model"
    ))

    assert_equal({ input: 40, output: 20, cached: 10, model: "pi-model" }, result)
  end

  def test_pi_final_event_without_usage_zero_fills
    result = PI.call(event("type" => "task.completed"))

    assert_equal({ input: 0, output: 0, cached: 0, model: nil }, result)
  end
end
