---
title: Patrol scans fresh remote defaults
type: log
created: 2026-07-17
tags: [patrol, git, worktree, freshness]
---

**Action:** Changed every new ordinary-patrol sweep to fetch and review the
exact `refs/heads/<default_branch>` commit instead of resolving a potentially
stale local default branch. The explicit source ref cannot be shadowed by a
same-named tag, and a process-group deadline bounds stalled transports. A
configured remote fetch failure now stops before mapper or reviewer work;
repositories without an origin retain the local-only path. An active snapshot
that Git can no longer materialize restarts at the current default and cursor
zero instead of remaining stuck.

**Safety chain:** The scan checkout leaves the operator's local default branch
untouched. The fixer independently re-fetches immediately before creating each
patrol branch, publication verifies the remote base before and after the leased
push, and synthetic `6-review` handoff requires the created PR's exact validated
base/head identity, and rechecks the live remote head/base immediately before
every first or retried task handoff. An older cursor-pinned review snapshot or
failed-handoff retry therefore cannot create a task on an old-base branch.

**Coverage:** `test/integration/patrol_command_test.rb` advances a bare remote
while local main stays behind, proves the detached scan uses the remote commit,
and proves an unreachable configured origin fails before reviewer creation.
Real-Git coverage adds same-name branch/tag resolution and a TERM-resistant
stalled SSH transport; command and PR-opener regressions cover dead snapshot
replacement and base advancement before first/retried handoff.

Pages: [[commands/patrol]], [[modules/patrol]], [[modules/worktree]], [[testing]].
