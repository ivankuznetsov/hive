require_relative "../../test_helper"
require_relative "patrol_qualification_campaign"

class E2EPatrolQualificationTest < Minitest::Test
  def test_real_process_patrol_evidence_qualifies_the_candidate
    proof = Hive::E2E::PatrolQualificationCampaign.new.run!

    assert_equal "deterministic_proof_ready", proof.fetch("status")
    assert_equal 20, proof.fetch("cases")
    assert_equal 10, proof.dig("modules", "patrol", "decision_count")
    assert_equal 10,
                 proof.dig("modules", "architecture-patrol", "decision_count")
  end
end
