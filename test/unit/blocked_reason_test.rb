require "test_helper"
require "hive/blocked_reason"

class BlockedReasonTest < Minitest::Test
  def test_dominant_state_uses_one_total_precedence
    signals = {
      needs_input: true,
      error: true,
      recovery: true,
      running: true,
      queued: true,
      blocked: true,
      ready: true
    }

    assert_equal "needs-you", Hive::BlockedReason.dominant_state(**signals)
    assert_equal "error", Hive::BlockedReason.dominant_state(**signals.merge(needs_input: false))
    assert_equal "recovery", Hive::BlockedReason.dominant_state(**signals.merge(needs_input: false, error: false))
    assert_equal "running", Hive::BlockedReason.dominant_state(**signals.merge(needs_input: false, error: false, recovery: false))
    assert_equal "blocked", Hive::BlockedReason.dominant_state(**signals.merge(needs_input: false, error: false, recovery: false, running: false, queued: false))
    assert_equal "ready", Hive::BlockedReason.dominant_state(**signals.merge(needs_input: false, error: false, recovery: false, running: false, queued: false, blocked: false))
    assert_equal "idle", Hive::BlockedReason.dominant_state(**signals.transform_values { false })
  end

  def test_payload_composes_typed_dependency_remedy
    payload = Hive::BlockedReason.for(
      action_key: "ready_to_develop",
      blocked_by: "api:base-task",
      dependency_stage: "2-research"
    ).payload

    assert_equal "Dependency has not reached its admission gate", payload.fetch("summary")
    assert_match(/api:base-task/, payload.fetch("detail"))
    assert_equal "open_task", payload.fetch("remedies").first.fetch("kind")
  end
end
