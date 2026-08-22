require "test_helper"
require "hive/patrol/validator"
require "hive/patrol_fix/validation_receipt"

class PatrolFixValidationReceiptTest < Minitest::Test
  def test_builds_bounded_redacted_command_evidence_and_preserves_failure
    started = Time.utc(2026, 8, 20, 12, 0, 0)
    result = Hive::Patrol::Validator::CommandResult.new(
      name: "focused-test", command: "bundle exec ruby test/focused_test.rb",
      exit_code: 7, signal: nil, stdout: "token=ghp_#{'u' * 36}",
      stderr: "failed", timed_out: false, output_truncated: false,
      started_at: started, finished_at: started + 1.25, duration_ms: 1_250,
      provenance: "agent"
    )

    payload = Hive::PatrolFix::ValidationReceipt.build(
      worktree_head: "b" * 40, results: [ result ]
    )

    assert_equal "failed", payload.fetch("verdict")
    command = payload.fetch("commands").first
    assert_equal "focused-test", command.fetch("identity")
    assert_equal "agent", command.fetch("provenance")
    assert_equal 7, command.fetch("exit_status")
    assert_equal 1_250, command.fetch("duration_ms")
    refute_includes command.fetch("stdout"), "ghp_"
    assert_match(/\A[0-9a-f]{64}\z/, command.fetch("command_digest"))
    assert_match(/\A[0-9a-f]{64}\z/, command.fetch("result_digest"))
  end

  def test_empty_deliberate_command_set_is_blocked_evidence
    payload = Hive::PatrolFix::ValidationReceipt.build(
      worktree_head: "b" * 40, results: []
    )

    assert_equal "blocked", payload.fetch("verdict")
    assert_empty payload.fetch("commands")
  end

  def test_receipt_level_output_truncation_is_marked_and_retained_in_the_result_digest
    started = Time.utc(2026, 8, 20, 12, 0, 0)
    build = lambda do |prefix|
      result = Hive::Patrol::Validator::CommandResult.new(
        name: "focused-test", command: "bundle exec ruby test/focused_test.rb",
        exit_code: 0, signal: nil, stdout: "#{prefix}#{"é" * 2_500}", stderr: "",
        timed_out: false, output_truncated: false,
        started_at: started, finished_at: started + 1, duration_ms: 1_000,
        provenance: "controller"
      )
      Hive::PatrolFix::ValidationReceipt.build(
        worktree_head: "b" * 40, results: [ result ]
      ).fetch("commands").first
    end

    first = build.call("first-prefix")
    second = build.call("second-prefix")

    assert first.fetch("output_truncated")
    assert_operator first.fetch("stdout").bytesize, :<=,
                    Hive::PatrolFix::ValidationReceipt::OUTPUT_BYTES
    assert first.fetch("stdout").valid_encoding?
    refute_equal first.fetch("result_digest"), second.fetch("result_digest")
  end
end
