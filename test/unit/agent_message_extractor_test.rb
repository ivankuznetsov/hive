require "test_helper"
require "hive/agent/message_extractor"

class AgentMessageExtractorTest < Minitest::Test
  def test_extracts_claude_result_message
    assert_equal "Final title",
                 Hive::Agent::MessageExtractor.extract({ "type" => "result", "result" => "Final title" })
  end

  def test_extracts_codex_item_completed_message
    event = {
      "type" => "item.completed",
      "item" => {
        "type" => "agent_message",
        "content" => [ { "type" => "output_text", "text" => "Codex title" } ]
      }
    }
    assert_equal "Codex title", Hive::Agent::MessageExtractor.extract(event)
  end

  def test_extracts_from_json_line
    line = JSON.generate("type" => "agent_message", "text" => "Line title")
    assert_equal "Line title", Hive::Agent::MessageExtractor.extract(line)
  end

  def test_extracts_grok_text_chunk_without_stripping_significant_space
    event = { "type" => "text", "data" => " a summary" }

    assert_equal " a summary", Hive::Agent::MessageExtractor.extract(event)
    assert Hive::Agent::MessageExtractor.streaming_text_event?(event)
  end

  def test_accumulator_replaces_streaming_text_with_complete_result
    accumulator = Hive::Agent::MessageExtractor::Accumulator.new(max_bytes: 64)
    accumulator.observe({ "type" => "text", "data" => "streamed " })
    accumulator.observe({ "type" => "text", "data" => "draft" })
    accumulator.observe({ "type" => "result", "result" => "Complete result" })

    assert_equal "Complete result", accumulator.value
    assert_equal :structured, accumulator.source
    refute accumulator.truncated?
  end

  def test_accumulator_replaces_streaming_text_with_complete_item
    accumulator = Hive::Agent::MessageExtractor::Accumulator.new(max_bytes: 64)
    accumulator.observe({ "type" => "text", "data" => "streamed " })
    accumulator.observe({ "type" => "text", "data" => "draft" })
    accumulator.observe({
      "type" => "item.completed",
      "item" => {
        "type" => "agent_message",
        "content" => [ { "type" => "output_text", "text" => "Complete item" } ]
      }
    })

    assert_equal "Complete item", accumulator.value
    assert_equal :structured, accumulator.source
    refute accumulator.truncated?
  end

  def test_accumulator_never_exposes_truncated_structured_message_as_complete
    accumulator = Hive::Agent::MessageExtractor::Accumulator.new(max_bytes: 5)
    accumulator.observe({ "type" => "text", "data" => "abc" })
    accumulator.observe({ "type" => "text", "data" => "def" })

    assert_nil accumulator.value
    assert_equal :structured_truncated, accumulator.source
    assert accumulator.truncated?

    accumulator.observe({ "type" => "text", "data" => "ghi" })

    assert_nil accumulator.value
    assert_equal :structured_truncated, accumulator.source

    accumulator.observe({ "type" => "result", "result" => "abcdef" })

    assert_nil accumulator.value
    assert_equal :structured_truncated, accumulator.source

    accumulator.observe({ "type" => "result", "result" => "exact" })

    assert_equal "exact", accumulator.value
    assert_equal :structured, accumulator.source
    refute accumulator.truncated?
  end

  def test_accumulator_keeps_bounded_plain_tail
    plain = Hive::Agent::MessageExtractor::Accumulator.new(max_bytes: 5)
    plain.observe(nil, raw_line: "abcdef")

    assert_equal "bcdef", plain.value
    assert_equal :plain, plain.source
    refute plain.truncated?
  end

  def test_budget_failure_omits_an_invalid_observed_cost
    failure = Hive::Agent::MessageExtractor.extract_failure(
      "type" => "result",
      "subtype" => "error_max_budget_usd",
      "total_cost_usd" => "not-a-number"
    )

    assert_equal "budget_exhausted", failure.fetch(:origin)
    refute failure.key?(:observed_cost_usd)
  end
end
