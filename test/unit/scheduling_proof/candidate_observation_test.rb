require "test_helper"
require "hive/scheduling_proof/candidate_observation"

class SchedulingProofCandidateObservationTest < Minitest::Test
  def test_normalizes_string_time_and_nested_array_evidence
    secret = "sk-#{'a' * 90}"
    candidate = Hive::SchedulingProof::CandidateObservation.build(
      row: {
        project: "demo", id: 7, slug: "task", folder: "/tmp/task",
        workflow: "coding", stage: "4-execute", condition_task_generation: 2,
        action: "needs_input", suggested_command: "hive develop task --from 4-execute"
      },
      reason: "needs_input", observed_at: "2026-07-17T12:00:00Z",
      evidence: { provider: [ { summary: "token #{secret}" }, "codex" ] }
    )

    assert_equal "2026-07-17T12:00:00.000000Z", candidate.fetch("observed_at")
    assert_equal "codex", candidate.dig("provider", 1)
    refute_includes candidate.dig("provider", 0, "summary"), secret
    assert_equal "answer", candidate.dig("action", "kind")
  end
end
