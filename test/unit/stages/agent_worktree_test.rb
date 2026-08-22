require "test_helper"
require "hive/stages/agent_worktree"

class AgentWorktreeCharacterizationTest < Minitest::Test
  def test_existing_draft_pr_path_still_owns_remote_handoff_and_terminal_resume
    assert_includes Hive::Stages::AgentWorktree::PROTECTED_FILES, "handoff.yml"
    assert_includes Hive::Stages::AgentWorktree::PROTECTED_FILES, "pr.md"
    assert_respond_to Hive::Stages::AgentWorktree, :prepare!
    assert_equal %i[worktree_path task_branch base_branch base_oid repository],
                 Hive::Stages::AgentWorktree::Context.members
  end
end
