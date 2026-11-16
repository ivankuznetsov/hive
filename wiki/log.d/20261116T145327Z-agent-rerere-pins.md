---
title: Agent git no longer replays stale rerere resolutions
type: fix
created: 2026-11-16
updated: 2026-11-16
tags: [agent, babysitter, rebase, git, incident]
---

On todero PR #57, the babysitter PR fixer's "Merge main into PR #57 branch"
(a42dd41) downgraded brakeman 8.1.0 to 8.0.6 in `Gemfile.lock`. The operator's
global git config sets `rerere.enabled` and `rerere.autoupdate`. Git staged a
resolution recorded back when main still had 8.0.6, and the agent never noticed
the lockfile change. Hive's managed git ignores global config, but git that
agents run themselves inherits it.

- New `Hive::GitConfigPins` appends `rerere.enabled=false` and
  `rerere.autoupdate=false` as `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` /
  `GIT_CONFIG_VALUE_n` entries. They override every config file and go after
  entries the child already has, so the operator's other config (identity,
  signing, credential helpers) and Hive-owned entries keep working.
- `Hive::Agent#child_environment` applies the pins to every agent spawn:
  stage agents, review fix, rebase conflict resolution, Patrol Fix, the live
  babysitter fixer, and native OpenCode. Inherited `ENV` entries are counted
  for normal spawns, but not for isolated or managed-policy spawns
  (`unsetenv_others`).
- `GitOps#rebase_onto` / `#rebase_continue` use the same pins. Before this, a
  replayed resolution left nothing unmerged, and `Hive::Rebase` continued the
  rebase itself without dispatching the conflict agent.
- The babysitter dry-run spawns with `pin_git_config: false`. Its git is the
  PATH stub, and `GitPolicy` still refuses every `GIT_CONFIG_COUNT` that is
  not `0`, including Hive's own pins. The check is unchanged.
- **Regression tests:** real `git merge` (agent environment) and `git rebase`
  plus `--continue` (GitOps) runs in temporary repositories with a recorded
  resolution and a fake global config that enables rerere autoupdate. They
  leave the conflict unmerged, and they fail if the pins are removed. The
  tests also cover index arithmetic over inherited and Hive-owned entries,
  PrFixer's live/dry-run choice, and the stub still refusing both an
  operator-supplied count and Hive's pins.
