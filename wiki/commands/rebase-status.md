---
title: hive rebase-status
type: command
source: lib/hive/commands/rebase_status.rb
created: 2026-05-14
updated: 2026-05-14T12:00:00Z
tags: [command, rebase, read-only, inspector]
---

**TLDR**: `hive rebase-status TARGET` is the read-only inspector for the auto-rebase pre-step. It reports whether the next `hive run` would attempt a rebase, how far behind `origin/<default_branch>` the worktree is, and which guard (if any) would short-circuit. **Never mutates anything; never calls `git fetch`** — it uses whatever the local `origin/<default>` ref already points at. Originated from PR #69 review AGENT-O3: operators and agents want to ask "would hive rebase this task right now?" without paying the cost of running it.

## Usage

```
hive rebase-status <slug> [--project NAME] [--stage STAGE] [--json]
hive rebase-status <project>/.hive-state/stages/<N>-<stage>/<slug> [--json]
```

`TARGET` resolution is identical to [[commands/run]]: bare slug, slug + filters, or absolute folder path. The output describes what `Hive::Rebase.perform(task, cfg)` would do if invoked immediately — guard order mirrors [[modules/rebase]] one-for-one, except `fetch_default_branch` is deliberately skipped.

## States

| State | Text output | Meaning |
|-------|-------------|---------|
| `disabled` | `<slug>: auto-rebase DISABLED via cfg.rebase.enabled = false` | Project opted out |
| `no_worktree` | `<slug>: no worktree at this stage (<stage>); rebase not applicable` | Brainstorm/plan/inbox/done, or worktree path missing |
| `pre_existing_rebase` | `<slug>: pre-existing rebase state on disk; rebase would skip. Run `git -C <wt> rebase --abort` to clean up.` | A prior aborted run left `.git/rebase-merge/` or `rebase-apply/` |
| `dirty_worktree` | `<slug>: worktree dirty; rebase would skip until clean` | Uncommitted changes |
| `detached_head` | `<slug>: detached HEAD; rebase would skip` | HEAD doesn't point at a branch |
| `no_default_branch` | `<slug>: could not resolve default branch; rebase would skip` | Neither `cfg.default_branch` nor `git symbolic-ref refs/remotes/origin/HEAD` resolves |
| `no_drift` | `<slug>: 0 commits behind origin/<default>; nothing to rebase` | Already up-to-date relative to the locally-known `origin/<default>` |
| `would_rebase` | `<slug>: N commits behind origin/<default>; next `hive run` would attempt rebase` | Drift detected — `hive run` would invoke `Hive::Rebase.perform` |

## JSON envelope (`--json`)

```json
{
  "schema": "hive-rebase-status",
  "slug": "<slug>",
  "stage": "4-execute",
  "folder": "<absolute folder path>",
  "worktree_path": "<absolute worktree path>",
  "state": "would_rebase",
  "would_rebase": true,
  "commits_behind": 3,
  "default_branch": "main"
}
```

- `state` is one of the eight values in the table above (snake_case).
- `would_rebase` is `true` only when `state == "would_rebase"`.
- `commits_behind` and `default_branch` are present for `no_drift` and `would_rebase`; otherwise omitted.

This envelope is intentionally **not** validated against `hive-run.v1` — it's a sibling read-only schema. The producer is `Hive::Commands::RebaseStatus#emit_json`.

## Why no fetch?

Two reasons:

1. **Read-only contract.** `git fetch` mutates `.git/refs/remotes/origin/` even on a successful no-op. An inspector verb that asks "what would happen?" shouldn't have side effects an operator didn't ask for.
2. **What `hive run` would see.** If `hive run`'s fetch silently fails (network blip, permissions), it routes to `:fetch_failed` and continues against whatever `origin/<default>` already points at locally. `rebase-status` reflects exactly that — the locally-known view. An operator who wants a fresh view can `cd <worktree> && git fetch` themselves, then re-run `rebase-status`.

## Relationship to `hive run`

`rebase-status` is a strict subset of `Hive::Rebase.perform`'s guard logic, with the fetch + actual rebase removed. If `rebase-status` reports `would_rebase` with `commits_behind: N`, then `hive run` will start a rebase attempt of N commits (assuming nothing changes between the two invocations). If `rebase-status` reports a skip-state, `hive run` will surface the same state via `Hive::Rebase::Result.reason` in its JSON envelope.

## Backlinks

- [[commands/run]] — the runtime consumer.
- [[modules/rebase]] — the orchestrator.
- [[modules/git_ops]] — `commits_behind`, `dirty?`, `detached_head?`, `rebase_in_progress?`, `default_branch`.
