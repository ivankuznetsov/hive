require "test_helper"
require "hive/scheduling_proof/reason"

class SchedulingProofReasonTest < Minitest::Test
  def test_normalizes_daemon_policy_and_capacity_outcomes
    assert_equal "dependency_wait", Hive::SchedulingProof::Reason.normalize(:blocked_on_dependency)
    assert_equal "edit_debounce", Hive::SchedulingProof::Reason.normalize(:wait_for_debounce)
    assert_equal "global_capacity", Hive::SchedulingProof::Reason.normalize(:global_cap)
    assert_equal "terminal_error", Hive::SchedulingProof::Reason.normalize(:error)
  end

  def test_unknown_outcome_fails_closed
    assert_equal "live_evidence_unavailable", Hive::SchedulingProof::Reason.normalize("future-gate")
    assert Hive::SchedulingProof::Reason.valid?("provider_circuit_open")
    refute Hive::SchedulingProof::Reason.valid?("future-gate")
  end
end
