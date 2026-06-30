require "test_helper"
require "hive/review_error_reason"

class ReviewErrorReasonTest < Minitest::Test
  def test_detects_merge_conflict
    assert_equal "merge_conflict",
                 Hive::ReviewErrorReason.classify("CONFLICT (content): Merge conflict in lib/app.rb")
  end

  def test_detects_network_timeout
    assert_equal "network_timeout",
                 Hive::ReviewErrorReason.classify("Fetch failed: connect timed out while opening socket")
  end

  def test_detects_tool_permission_denied
    assert_equal "tool_permission_denied",
                 Hive::ReviewErrorReason.classify("tool shell_command blocked: permission denied")
  end

  def test_detects_agent_crashed
    assert_equal "agent_crashed",
                 Hive::ReviewErrorReason.classify("Traceback (most recent call last):")
  end

  def test_first_match_wins_by_reason_priority
    text = <<~TEXT
      process killed by signal
      Automatic merge failed; fix conflicts and then commit the result.
    TEXT

    assert_equal "merge_conflict", Hive::ReviewErrorReason.classify(text)
  end

  def test_unrecognized_text_is_unknown
    assert_equal "unknown",
                 Hive::ReviewErrorReason.classify("expected output file was not written before deadline")
  end

  def test_blank_and_nil_are_unknown
    assert_equal "unknown", Hive::ReviewErrorReason.classify("")
    assert_equal "unknown", Hive::ReviewErrorReason.classify(" \n\t ")
    assert_equal "unknown", Hive::ReviewErrorReason.classify(nil)
  end

  def test_ansi_and_control_characters_are_normalized_before_classification
    text = "\e[31mPermission denied\e[0m\u0007 while calling tool"

    assert_equal "tool_permission_denied", Hive::ReviewErrorReason.classify(text)
  end

  def test_classified_outputs_are_closed_over_enum
    emitted = Hive::ReviewErrorReason::CLASSIFIED + [ "unknown" ]

    assert_empty emitted - Hive::ReviewErrorReason::REASONS
  end

  def test_rate_limit_language_is_reserved_for_agent_limit_gate
    assert_equal "unknown", Hive::ReviewErrorReason.classify("rate limit reached")
    assert Hive::AgentLimit.limit_reached?("rate limit reached")
  end
end
