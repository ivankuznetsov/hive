---
title: Task dependencies
type: module
source: lib/hive/dependencies.rb, lib/hive/dependency_snapshot.rb, lib/hive/commands/status.rb, lib/hive/daemon/policy.rb, lib/hive/stages/execute.rb, lib/hive/stages/open_pr.rb
created: 2026-06-18
updated: 2026-06-22
tags: [task, dependencies, status, daemon, worktree, pr]
---

**TLDR**: A task can declare one `depends_on` prerequisite in durable
`meta.yml`. `hive status` resolves that dependency inside the same project,
surfaces the dependency fields in `hive-status` v4, and the daemon freezes
auto-dispatch while `blocked: true`. When the prerequisite reaches the gate
stage, dependent execute/open-pr stages stack on the prerequisite branch.

## Metadata

`depends_on` is stored in each task's `meta.yml`, not in the per-stage state
file. That keeps the dependency stable across `mv`-based stage transitions.
`Hive::Task#depends_on` delegates to `Hive::TaskMeta.read`, and `hive new
--depends-on <id-or-slug>` is the supported authoring path for new tasks.
Existing tasks can still be edited manually by changing `meta.yml`.

The value is a single id-or-slug string. Multi-dependency arrays and per-task
gate overrides are intentionally absent.

## Resolution

`Hive::Dependencies` is pure. Given a same-project task snapshot and a
configured threshold stage, it resolves by slug first and numeric id second.
The result carries:

- `blocked_by` - resolved prerequisite slug, or nil.
- `dependency_stage` - prerequisite stage directory, or nil.
- `blocked` - true when the prerequisite has not reached the threshold.
- `unresolved` - true for missing prerequisites and self-reference.

Missing/deleted prerequisites and self-reference are fail-closed: the dependent
stays blocked. Two-task cycles are not detected; they freeze both tasks until a
human edits metadata or moves/approves manually.

`dependency_gate_stage` is a top-level config key. The default is
`8-finalize`; the only other valid value is `9-done`.

## Status Contract

`hive status --json` is the source of truth. `Status#collect_rows` builds the
same-project snapshot, resolves dependency state for each row, and emits
`depends_on`, `blocked_by`, `dependency_stage`, and `blocked` on every task row.
This bumped `hive-status` to schema v4.

Text status and the TUI append a single inline indicator when a row is blocked:
`⏸ blocked by <slug> (<stage>)`. If the dependency is unresolved, the indicator
uses the raw dependency value and `(unresolved)`.

## Daemon Gate

`Hive::Daemon::StatusConsumer` reads the dependency fields from
`hive status --json`; it does not inspect task files directly.
`Hive::Daemon::Policy#decide` trusts the row's `blocked` boolean and returns
`:blocked_on_dependency` instead of dispatching forward actions. The dispatcher
logs a `:blocked` event with `reason: "dependency_unmet"` plus dependency
context.

The gate is daemon-only. Manual `hive run`, `hive approve`, and filesystem
`mv` operations bypass this policy path.

## Stacked Branches

When a dependent reaches `4-execute`, `Hive::Dependencies.base_branch_for`
returns the prerequisite slug as the intended base. `Hive::Worktree#create!`
then tries to create the dependent branch from `origin/<prerequisite-slug>`,
then local `refs/heads/<prerequisite-slug>`, then the freshest default branch.
If a same-named dependent branch already exists, real committed work is
preserved; only an empty placeholder branch — carrying no unique commits beyond
*either* default ref used for the emptiness check (`origin/<default>` when its
tracking ref exists, **and** local `<default>` when that branch exists) — is
deleted and recreated via the origin→local→default base resolution above.

When the same dependent reaches `5-open-pr`, `OpenPr#render_prompt` includes
`--base <prerequisite-slug>` in the `gh pr create` command only if the
prerequisite branch still exists on origin. If it has already merged and been
deleted, Hive omits `--base` and lets GitHub target the default branch.

## Backlinks

- [[modules/task]] · [[commands/status]] · [[modules/daemon]]
- [[modules/worktree]] · [[stages/execute]] · [[stages/open-pr]]
