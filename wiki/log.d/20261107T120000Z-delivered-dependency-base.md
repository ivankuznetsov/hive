# 2026-11-07 — execute: never stack on a delivered dependency's stale branch

**Action:** Fixed `hive develop` creating the execute worktree of
`let-the-native-hive-cli-260923-01dd` on the stale local branch of its
prerequisite `extend-idempotency-keys-and-durable-260923-ccce`, which was in
`9-done` and squash-merged as PR #1494 with its remote branch deleted. The log
read `fetch origin <prereq> failed (couldn't find remote ref); stacking on
local <prereq>`; `worktree.yml` recorded `base_branch: main` but
`base_oid`/`execute_base_head` = the pre-squash local commit, which is not an
ancestor of main, so the worktree lacked six weeks of main and the task fell to
"Needs execution repair".

**Root cause:** `DependencySnapshot.base_selection` returned a stacked base for
any resolvable same-project scalar regardless of the prerequisite's delivery
state, and `Worktree#freshest_override_base` then fell back remote → local, so
a delivered prerequisite's leftover local branch silently became the base.

**Change:**
- `DependencySnapshot.base_selection` returns `mode: default` (with a warning)
  when the prerequisite has delivered evidence: stage `9-done`, or
  `PullRequestOutcome.latest(folder)` merged. Applies to execute, open-PR, and
  status/fingerprint base mode alike. `tasks` rows now carry `folder`.
- The undelivered local-only fallback keeps the documented remote → local →
  default order but its warning now names the hazard (no remote branch, local
  branch unverified/may be stale).
- `Worktree#resolved_base` exposes the start ref; execute records it as
  `base_ref` in `worktree.yml` next to `base_branch`/`base_oid`.

**Docs:** `wiki/modules/task_dependencies.md`, `wiki/modules/worktree.md`,
`wiki/commands/status.md`, `wiki/modules/task_workspace.md`.

**Tests:** `test/integration/dependency_stacked_base_test.rb` (real git:
delivered prerequisite with deleted remote + stale local → origin/master;
undelivered with remote → stacks; undelivered remote-missing local-present →
loud local stack with `base_ref: refs/heads/<prereq>`),
`test/unit/dependency_snapshot_test.rb` (9-done, merged vs open PR, admission
context), execute pointer `base_ref`; status fixtures that modelled a stacked
prerequisite in `9-done` moved to `8-finalize`.
