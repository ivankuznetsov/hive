require "hive"
require "hive/worktree"

module Hive
  # Shared action builder for `EXECUTE_WAITING reason=...` recovery states.
  # Used by `hive run --json`, `hive status --json`, and the TUI so every
  # consumer sends the operator or agent to the same repair target.
  module ExecuteWaitingAction
    module_function

    def build(task, marker, rerun_with: nil)
      reason = marker.attrs["reason"].to_s
      action = action_for_reason(task, reason)
      action["rerun_with"] = rerun_with if rerun_with
      action
    end

    def action_for_reason(task, reason)
      kind = Hive::Schemas::NextActionKind
      worktree_path = worktree_path_for(task)

      case reason
      when "dirty_worktree"
        {
          "kind" => kind::EDIT,
          "target" => worktree_path,
          "instructions" => "the execute agent left uncommitted work; inspect the worktree, commit intended " \
                            "changes or remove unintended files, then re-run"
        }
      when "branch_mismatch", "head_not_descendant"
        {
          "kind" => kind::EDIT,
          "target" => worktree_path,
          "instructions" => "the worktree HEAD is not on the expected task branch or no longer descends from " \
                            "the execute baseline; recover the intended commits onto the task branch, then re-run"
        }
      when "no_worktree_changes"
        {
          "kind" => kind::EDIT,
          "target" => File.join(task.folder, "plan.md"),
          "instructions" => "the execute agent exited without a new worktree commit; if this was intentional " \
                            "research, add `execution_mode: research` to plan.md frontmatter and re-run, " \
                            "otherwise update the worktree and commit the implementation"
        }
      when "missing_research_output"
        {
          "kind" => kind::RUN,
          "target" => task.folder,
          "instructions" => "research-mode execute needs a structured final agent message; inspect the " \
                            "agent/profile/prompt output, then re-run so Hive can capture the final answer " \
                            "under `## Execute Output`"
        }
      else
        {
          "kind" => kind::EDIT,
          "target" => task.state_file,
          "instructions" => "inspect the execute task state, make the requested changes, then re-run"
        }
      end
    end

    def worktree_path_for(task)
      pointer = Hive::Worktree.read_pointer(task.folder) || {}
      pointer["path"] || task.folder
    end
  end
end
