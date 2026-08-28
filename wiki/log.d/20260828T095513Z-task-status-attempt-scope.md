---
date: 2026-08-28
tags: [status, task, attempts, patrol-fix]
pages: [commands/status, commands/task]
---

# Keep bounded task status inside an attempts-store scope

Direct `Status#project_payload` consumers now open one scan-scoped read-only
attempt store when no outer status scan already owns one. This preserves the
single-store full-scan optimization while allowing `hive task` to project
receipt-bound Patrol failure diagnostics instead of raising `status attempt
store is outside a scan` during action annotation.

Focused status coverage exercises the direct project boundary and proves that
the store is shared through annotation and released afterward. Live source
verification also resolved the two previously failing Patrol task workspaces
to their exact `secret_policy_publish_blocked` and `fix_worktree_dirty`
diagnostics.
