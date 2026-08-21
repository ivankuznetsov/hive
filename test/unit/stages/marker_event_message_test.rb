require "test_helper"
require "hive/stages/base"

# A marker records only the most recent failure — the next run overwrites it.
# The reason code alone does not distinguish causes: one 7-artifacts task
# failed 25 times under `outcome_evidence_invalid` for three unrelated
# reasons, and by the time anyone looked only the last was recoverable.
# events.jsonl is append-only, so the diagnostic must travel with the event.
class MarkerEventMessageTest < Minitest::Test
  Marker = Struct.new(:name, :attrs)

  def marker_message(name, attrs)
    Hive::Stages::Base.send(:marker_event_message, Marker.new(name, attrs))
  end

  def test_diagnostic_travels_with_the_error_event
    result = marker_message(:error, {
      "reason" => "outcome_evidence_invalid",
      "diagnostic" => "review verdict reason must be a meaningful bounded explanation"
    })

    assert_includes result, "outcome_evidence_invalid"
    assert_includes result, "review verdict reason must be a meaningful bounded explanation",
                    "the cause must survive the marker being overwritten"
  end

  def test_two_failures_sharing_a_reason_remain_distinguishable
    missing = marker_message(:error, {
      "reason" => "outcome_evidence_invalid",
      "diagnostic" => "reviewer output is missing or oversized"
    })
    verdict = marker_message(:error, {
      "reason" => "outcome_evidence_invalid",
      "diagnostic" => "review verdict reason must be a meaningful bounded explanation"
    })

    refute_equal missing, verdict
  end

  # Stages disagree on the key: artifacts writes `diagnostic`, the council
  # writes `message`. Reading only one left every council_failed as a bare
  # reason code, with no way to tell a crashed reviewer from a failed revise.
  def test_a_council_message_is_carried_like_a_diagnostic
    result = marker_message(:error, {
      "reason" => "council_failed",
      "message" => "council reviewer grok-doc-review failed: exited 1"
    })

    assert_includes result, "council_failed"
    assert_includes result, "council reviewer grok-doc-review failed"
  end

  def test_a_marker_without_a_diagnostic_is_unchanged
    assert_equal "error outcome_evidence_invalid",
                 marker_message(:error, { "reason" => "outcome_evidence_invalid" })
    assert_equal "complete", marker_message(:complete, {})
  end

  def test_an_oversized_diagnostic_is_bounded
    result = marker_message(
      :error, { "reason" => "boom", "diagnostic" => "x" * 5_000 }
    )

    assert_operator result.bytesize, :<=,
                    Hive::Stages::Base::MAX_EVENT_DIAGNOSTIC_BYTES + 64
  end

  def test_a_blank_diagnostic_adds_nothing
    assert_equal "error boom",
                 marker_message(:error, { "reason" => "boom", "diagnostic" => "   " })
  end
end
