## Resume automatic closure for pre-head-metadata tasks

- The final daemon closure guard now uses the same fail-closed legacy head
  recovery as merge candidate observation: when `pr.md` predates immutable
  head metadata, only the HEAD of the task's strictly owned canonical worktree
  can bind the task to the verified merged PR.
- Missing, malformed, relocated, or differently headed worktrees still block
  automatic archive.
- The real merge-watcher regression now completes the evidence-bound closure
  transition and verifies that an older task reaches `9-done`, instead of
  stopping at a fake closure call.
