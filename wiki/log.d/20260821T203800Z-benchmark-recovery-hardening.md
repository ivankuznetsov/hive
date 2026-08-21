## 2026-08-21: Harden loaded-runner and dirty-execute recovery

**Action:** Raised the shared agent CLI version/help probe deadline from 30 to
120 seconds after parallel benchmark containers repeatedly exceeded 30 seconds
during cold Pi startup despite completing promptly once warm. The process-group
kill and fail-closed timeout behavior remain unchanged.

**Action:** Admitted the current `ERROR reason=dirty_worktree` execute marker to
`hive worktree commit-residue`. The command already accepted the historical
`EXECUTE_WAITING` form and uses CleanExit's scope, symlink, secret-content,
signing, ownership, and task-lock guards; the marker still remains for a fresh
generation-guarded coordinator retry after the residue is committed.

**Action:** Corrected residue-command pointer validation to pass the task's
project root to `Worktree.canonical_root`. Passing the configured worktree
directory there caused a second config lookup and bogus roots such as
`.worktrees.worktrees`, preventing safe recovery even for valid owned pointers.

**Evidence:** `test/unit/agent_profile_test.rb` retains the bounded timeout and
process cleanup coverage. `test/unit/commands/worktree_test.rb` now pins guarded
commit recovery from the current execute marker without clearing its marker ID.
