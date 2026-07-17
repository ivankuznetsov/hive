require "test_helper"
require "hive/scheduling_proof/action_projector"

class SchedulingProofActionProjectorTest < Minitest::Test
  def test_preserves_one_existing_safe_command_with_generation_fence
    action = Hive::SchedulingProof::ActionProjector.project(
      reason: "needs_input", action_key: "needs_input",
      command: "hive develop task-260717-abcd --from 4-execute",
      stage: "4-execute", task_generation: 3, attempt_id: nil
    )

    assert_equal "answer", action.fetch("kind")
    assert_equal "hive develop task-260717-abcd --from 4-execute", action.fetch("command")
    assert_equal 3, action.dig("preconditions", "task_generation")
    assert_equal [ "kind", "text", "command", "requires_confirmation", "preconditions" ].sort,
                 action.keys.sort
  end

  def test_rejects_shell_composition_and_forbidden_bypass_commands
    [
      "hive run task; rm -rf /tmp/x",
      "hive markers clear task",
      "systemctl --user restart hive-daemon",
      "hive archive task --force"
    ].each do |command|
      action = Hive::SchedulingProof::ActionProjector.project(
        reason: "terminal_error", action_key: "error", command: command,
        stage: "4-execute", task_generation: 2, attempt_id: "attempt-1"
      )
      assert_equal "no_safe_action", action.fetch("kind")
      assert_nil action.fetch("command")
    end
  end

  def test_accounting_inconsistency_always_suppresses_advice
    action = Hive::SchedulingProof::ActionProjector.project(
      reason: "accounting_inconsistent", action_key: "ready_to_run", command: "hive run task",
      stage: "2-work", task_generation: 4, attempt_id: nil
    )

    assert_equal "no_safe_action", action.fetch("kind")
    assert_nil action.fetch("command")
  end

  def test_rejects_a_shell_command_with_invalid_quoting
    action = Hive::SchedulingProof::ActionProjector.project(
      reason: "terminal_error", action_key: "error", command: "hive run 'unterminated",
      stage: "4-execute", task_generation: 2, attempt_id: nil
    )

    assert_equal "no_safe_action", action.fetch("kind")
    assert_nil action.fetch("command")
  end
end
