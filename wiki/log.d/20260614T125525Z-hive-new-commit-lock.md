---
date: 2026-06-14
slug: hive-new-commit-lock
pages: [commands/new, testing]
---

Fixed a process-level `hive new` race exposed by the hivebox web system job:
parallel Rails/system-test workers could capture ideas against the same
project and run concurrent `Hive::GitOps#hive_commit` calls in the shared
`.hive-state` worktree. Git then failed on the worktree `index.lock`, leaving
the web suite with partial `.hive-state` setup errors such as existing
`hive/state` branches or unparseable HEADs.

`Hive::Commands::New#call!` now imports `Hive::Lock` explicitly and wraps the
captured-task `hive_commit(stage_name: "1-inbox", action: "captured")` in
`Hive::Lock.with_commit_lock(hive_state)`, matching the existing commit-lock
contract used by run/approve/drop/markers. The lock covers only the short
`git add && git commit` window; task file creation, id allocation, and
best-effort display-name generation remain outside it.

Added `test_new_serializes_hive_state_commit` to `test/integration/new_test.rb`
and verified a direct multi-process repro: before the change, 3 of 8 child
processes failed with git `index.lock` errors; after the change, all 8 exited
0 with no failure logs. Updated [[commands/new]] and [[testing]]. No index
change was needed because no new wiki page was created.
