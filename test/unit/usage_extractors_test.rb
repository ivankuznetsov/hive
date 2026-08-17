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

    assert_equal(
      {
        input: 0, output: 0, cached: 0, cache_read: 0, cache_write: 0,
        reasoning: nil, input_includes_cache_read: false,
        input_includes_cache_write: false, output_includes_reasoning: nil,
        model: nil
      },
      result
    )
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

    assert_equal(
      {
        input: 123, output: 45, cached: 13, cache_read: 6, cache_write: 7,
        reasoning: nil, input_includes_cache_read: false,
        input_includes_cache_write: false, output_includes_reasoning: nil,
        model: "claude-opus-4-7[1m]"
      },
      result
    )
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

    assert_equal(
      {
        input: 3, output: 2, cached: 5, cache_read: 1, cache_write: 4,
        reasoning: nil, input_includes_cache_read: false,
        input_includes_cache_write: false, output_includes_reasoning: nil,
        model: nil
      },
      result
    )
  end

  def test_claude_message_start_extracts_nested_message_usage
    result = CLAUDE.call(event(
      "type" => "stream_event",
      "event" => {
        "type" => "message_start",
        "message" => {
          "model" => "claude-opus-4-8",
          "usage" => {
            "input_tokens" => 30,
            "output_tokens" => 4,
            "cache_read_input_tokens" => 70
          }
        }
      }
    ))

    assert_equal(
      {
        input: 30, output: 4, cached: nil, cache_read: 70, cache_write: nil,
        reasoning: nil, input_includes_cache_read: false,
        input_includes_cache_write: nil, output_includes_reasoning: nil,
        model: "claude-opus-4-8"
      },
      result
    )
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

    assert_equal(
      {
        input: 1000, output: 200, cached: 300, cache_read: nil,
        cache_write: nil, reasoning: nil, input_includes_cache_read: nil,
        input_includes_cache_write: nil, output_includes_reasoning: nil,
        model: "gpt-5-codex"
      },
      result
    )
  end

  def test_codex_final_event_without_usage_remains_unknown
    result = CODEX.call(event("type" => "turn.completed", "model" => "gpt-5-codex"))

    assert_nil result
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

    assert_equal(
      {
        input: 40, output: 20, cached: nil, cache_read: 10,
        cache_write: nil, reasoning: nil, input_includes_cache_read: nil,
        input_includes_cache_write: nil, output_includes_reasoning: nil,
        model: "pi-model"
      },
      result
    )
  end

  def test_pi_final_event_without_usage_remains_unknown
    result = PI.call(event("type" => "task.completed"))

    assert_nil result
  end

  # Verbatim shape from a real pi run: usage sits on the assistant message and
  # uses bare input/output/cacheRead spellings. The extractor previously read
  # neither, so every pi run in the usage database was unmetered — zero rows
  # against thousands for claude, codex and grok.
  def test_pi_reports_usage_from_the_assistant_message
    result = PI.call(event(
      "type" => "message_end",
      "message" => {
        "role" => "assistant",
        "provider" => "openrouter",
        "model" => "deepseek/deepseek-v4-pro",
        "usage" => {
          "input" => 14_206, "output" => 759,
          "cacheRead" => 148_864, "cacheWrite" => 0,
          "totalTokens" => 163_829
        },
        "stopReason" => "stop"
      }
    ))

    refute_nil result, "pi usage must be read from the assistant message"
    assert_equal 14_206, result.fetch(:input)
    assert_equal 759, result.fetch(:output)
    assert_equal 148_864, result.fetch(:cache_read)
    assert_equal 0, result.fetch(:cache_write)
    assert_equal "deepseek/deepseek-v4-pro", result.fetch(:model)
  end

  # The bare spellings are matched last, so a provider that reports explicit
  # *_tokens keys keeps its own reading even when both are present.
  def test_explicit_token_keys_still_win_over_the_bare_spellings
    result = CLAUDE.call(event(
      "type" => "result",
      "usage" => {
        "input_tokens" => 11, "output_tokens" => 22,
        "input" => 999, "output" => 888
      }
    ))

    assert_equal 11, result.fetch(:input)
    assert_equal 22, result.fetch(:output)
  end
end
