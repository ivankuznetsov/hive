PATROL_FIX_QUALIFICATION_PATH_KEYS = %w[
  HIVE_PATROL_FIX_QUALIFICATION_PROJECT
  HIVE_PATROL_FIX_QUALIFICATION_EVIDENCE
].freeze

# This file is the explicit authenticated smoke boundary. Preserve the normal
# test-suite HOME isolation unless both absolute opt-in paths were supplied
# before test_helper selects the process environment.
if PATROL_FIX_QUALIFICATION_PATH_KEYS.all? { |key| ENV[key].to_s.start_with?("/") }
  ENV["HIVE_TEST_ALLOW_REAL_USER_ENV"] = "1"
else
  ENV.delete("HIVE_TEST_ALLOW_REAL_USER_ENV")
end

require_relative "../../test_helper"
require_relative "../lib/patrol_qualification"

class E2EPatrolFixLiveQualificationTest < Minitest::Test
  def test_configured_providers_clear_the_frozen_four_gate_corpus
    missing = PATROL_FIX_QUALIFICATION_PATH_KEYS.reject do |key|
      ENV[key].to_s.start_with?("/")
    end
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
