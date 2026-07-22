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

  def test_accumulator_bounds_streaming_messages_and_keeps_plain_tail
    accumulator = Hive::Agent::MessageExtractor::Accumulator.new(max_bytes: 5)
    accumulator.observe({ "type" => "text", "data" => "abc" })
    accumulator.observe({ "type" => "text", "data" => "def" })

    assert_equal "abcde", accumulator.value
    assert_equal :structured, accumulator.source

    plain = Hive::Agent::MessageExtractor::Accumulator.new(max_bytes: 5)
    plain.observe(nil, raw_line: "abcdef")

    assert_equal "bcdef", plain.value
    assert_equal :plain, plain.source
  end
end
