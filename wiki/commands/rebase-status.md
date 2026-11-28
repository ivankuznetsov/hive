---
title: hive rebase-status
type: command
source: lib/hive/commands/rebase_status.rb
created: 2026-05-14
updated: 2026-11-20
tags: [command, rebase, read-only, inspector]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-rebase-status) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive rebase-status TARGET` is the read-only inspector for the auto-rebase pre-step. It reports whether the next `hive run` would attempt a rebase, how far behind `origin/<default_branch>` the worktree is, and which guard (if any) would short-circuit. **Never mutates anything; never calls `git fetch`** — it uses whatever the local `origin/<default>` ref already points at. Originated from PR #69 review AGENT-O3: operators and agents want to ask "would hive rebase this task right now?" without paying the cost of running it.

## States

`TARGET` resolution mirrors [[commands/run]]; guard evaluation mirrors [[modules/rebase]] one-for-one except `fetch_default_branch` is deliberately skipped.

| State | Text output | Meaning |
|-------|-------------|---------|
| `controller_workflow` | `<slug>: controller workflow owns checkout movement; generic auto-rebase does not apply` | The workflow's receipts and controller own the checkout |
| `managed_draft_pr_handoff` | `<slug>: draft-PR handoff owns exact checkout identity; generic auto-rebase does not apply` | The managed handoff receipt owns the checkout pair |
| `disabled` | `<slug>: auto-rebase DISABLED via cfg.rebase.enabled = false` | Project opted out |
| `published_review_branch` | `<slug>: pull request is published and in review; Hive never rewrites it. Recover base drift with a merge commit (no rebase, no force-push)` | The task is in a review-runner stage and `github-publication.json` exists or `pr.md` carries a `pr_url` |
| `no_worktree` | `<slug>: no worktree at this stage (<stage>); rebase not applicable` | Brainstorm/plan/inbox/done, or worktree path missing |
| `pre_existing_rebase` | `<slug>: pre-existing rebase state on disk; rebase would skip. Run `git -C <wt> rebase --abort` to clean up.` | A prior aborted run left `.git/rebase-merge/` or `rebase-apply/` |
| `dirty_worktree` | `<slug>: worktree dirty; rebase would skip until clean` | Uncommitted changes |
| `detached_head` | `<slug>: detached HEAD; rebase would skip` | HEAD doesn't point at a branch |
| `no_default_branch` | `<slug>: could not resolve default branch; rebase would skip` | Neither `cfg.default_branch` nor `git symbolic-ref refs/remotes/origin/HEAD` resolves |
| `no_drift` | `<slug>: 0 commits behind origin/<default>; nothing to rebase` | Already up-to-date relative to the locally-known `origin/<default>` |
| `would_rebase` | `<slug>: N commits behind origin/<default>; next `hive run` would attempt rebase` | Drift detected — `hive run` would invoke `Hive::Rebase.perform` |

## Why no fetch?

Two reasons:

1. **Read-only contract.** `git fetch` mutates `.git/refs/remotes/origin/` even on a successful no-op. An inspector verb that asks "what would happen?" shouldn't have side effects an operator didn't ask for.
2. **What `hive run` would see.** If `hive run`'s fetch silently fails (network blip, permissions), it routes to `:fetch_failed` and continues against whatever `origin/<default>` already points at locally. `rebase-status` reflects exactly that — the locally-known view. An operator who wants a fresh view can `cd <worktree> && git fetch` themselves, then re-run `rebase-status`.

## Relationship to `hive run`

`rebase-status` mirrors `hive run`'s complete auto-rebase guard order, with the fetch + actual rebase removed. Controller workflows and managed draft-PR handoffs are excluded before the generic `Hive::Rebase.perform` ladder. If `rebase-status` reports `would_rebase` with `commits_behind: N`, then `hive run` will start a rebase attempt of N commits (assuming nothing changes between the two invocations). If `rebase-status` reports a skip-state, `hive run` will surface the same state via `Hive::Rebase::Result.reason` in its JSON envelope.

## Backlinks

- [[commands/run]] — the runtime consumer.
- [[modules/rebase]] — the orchestrator.
- [[modules/git_ops]] — `commits_behind`, `dirty?`, `detached_head?`, `rebase_in_progress?`, `default_branch`.
