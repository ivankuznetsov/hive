require_relative "../../test_helper"
require_relative "../lib/patrol_qualification"

class E2EPatrolQualificationTest < Minitest::Test
  def test_prepared_real_patrol_records_qualify_through_the_installed_cli
    required = %w[
      HIVE_PATROL_QUALIFICATION_PROJECT
      HIVE_PATROL_QUALIFICATION_HOME
      HIVE_PATROL_QUALIFICATION_OBSERVATIONS
      HIVE_PATROL_QUALIFICATION_EVIDENCE
    ]
    missing = required.reject { |key| ENV[key].to_s.start_with?("/") }
    unless missing.empty?
      flunk "opt-in qualification requires absolute paths in: #{missing.join(', ')}"
    end

    proof = Hive::E2E::PatrolQualification::Controller.new(
      repo_root: File.expand_path("../../..", __dir__),
      project_root: ENV.fetch("HIVE_PATROL_QUALIFICATION_PROJECT"),
      hive_home: ENV.fetch("HIVE_PATROL_QUALIFICATION_HOME"),
      observations_path: ENV.fetch("HIVE_PATROL_QUALIFICATION_OBSERVATIONS"),
      evidence_root: ENV.fetch("HIVE_PATROL_QUALIFICATION_EVIDENCE")
    ).run!

    assert_equal "qualified_smoke", proof.fetch("status")
    assert_equal 20, proof.fetch("receipt_count")
    assert_includes proof.fetch("claim_fences"), "not_full_u3b"
    assert_includes proof.fetch("claim_fences"),
                    "same_candidate_controls_not_independent"
  end
end
