require_relative "../../test_helper"
require_relative "../lib/patrol_qualification"

class E2EPatrolFixLiveQualificationTest < Minitest::Test
  def test_configured_providers_clear_the_frozen_four_gate_corpus
    required = %w[
      HIVE_PATROL_FIX_QUALIFICATION_PROJECT
      HIVE_PATROL_FIX_QUALIFICATION_EVIDENCE
    ]
    missing = required.reject { |key| ENV[key].to_s.start_with?("/") }
    unless missing.empty?
      flunk "opt-in Patrol Fix qualification requires absolute paths in: #{missing.join(', ')}"
    end

    report = Hive::E2E::PatrolQualification::LiveDecisionCorpusController.new(
      project_root: ENV.fetch("HIVE_PATROL_FIX_QUALIFICATION_PROJECT"),
      corpus_path: File.expand_path(
        "../fixtures/patrol_fix_qualification/corpus.json", __dir__
      ),
      evidence_path: ENV.fetch("HIVE_PATROL_FIX_QUALIFICATION_EVIDENCE")
    ).run!

    assert_equal 8, report.fetch("cases").size
    refute report.fetch("cases").any? { |row| row.fetch("status") == "unsafe_disagreement" }
  end
end
