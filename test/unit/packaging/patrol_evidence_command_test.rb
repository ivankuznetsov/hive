require "test_helper"
require "open3"

class PatrolEvidenceCommandTest < Minitest::Test
  COMMAND = File.expand_path("../../../bin/hive-patrol-installed-live-smoke", __dir__)

  def test_manual_command_is_a_thin_local_only_runner_seam
    stdout, stderr, status = Open3.capture3(COMMAND, "--help")

    assert status.success?, stderr
    assert_includes stdout, "--controller-sha"
    assert_includes stdout, "--candidate-sha"
    assert_includes stdout, "--authorization-file"
    assert_includes stdout, "--evidence-root"
    assert_includes stdout, "--cleanup-result"
    assert_includes stdout, "--project-root"
    assert_includes stdout, "--observations"
    assert_includes stdout, "--image"
    refute_includes stdout, "API_KEY"
    refute_includes stdout, "credential"

    source = File.binread(COMMAND)
    assert_includes source, "HivePatrolEvidence::Runner.run!"
    refute_match(/PatrolQualification|admit_qualification|report\.json|evidence_ready_for_operator/, source)
    refute_match(/Net::HTTP|Open3|Process\.spawn|system\(/, source)
  end
end
