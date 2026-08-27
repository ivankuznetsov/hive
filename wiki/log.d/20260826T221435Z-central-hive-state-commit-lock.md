---
date: 2026-08-26
slug: central-hive-state-commit-lock
pages: [modules/git_ops, modules/lock, modules/patrol, commands/generate-name, testing, gaps]
---

Centralized runtime hive-state commit serialization in
`Hive::GitOps#hive_commit`. Scoped staging, the optional `after_stage`
validation callback, cached-diff inspection, and commit now execute inside one
project commit lock, so callers such as Patrol Fix transitions and asynchronous
display-name generation cannot bypass index serialization.

The commit lock now supports same-thread, same-process nesting for existing
larger transactions while binding local ownership to `Process.pid`; a forked
child cannot trust copied thread-local state. Focused tests cover nesting,
fork-inherited fail-closed behavior, process contention, exception cleanup,
kernel release after `SIGKILL`, and eight direct concurrent GitOps commits.

Patrol Fix existing-task materialization now keeps failure restoration and its
scoped index reset inside the same outer commit lock as the filesystem writes
and attempted commit. Two explicit gaps remain: first-time `hive_state_init`
bootstrap needs a separate project-level lifecycle lock because the worktree-local
lock does not exist yet, and no checked-in live hivebox Rails/system-worker
artifact replays the historical workload after this centralization. No index
update was needed because no wiki page was added.
