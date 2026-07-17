---
title: 9-done stage
type: stage
source: lib/hive/stages/done.rb, lib/hive/finalization/archive_cleanup.rb
created: 2026-04-25
updated: 2026-07-17
tags: [stage, done, archive, cleanup, journal]
---

**TLDR**: The terminal stage performs validated local cleanup and records a
durable receipt. It runs only after current `archive_ready` evidence; it never
deletes a remote branch.

## Guard and cleanup

`Hive::Finalization::ArchiveCleanup` rebuilds and validates finalization
history before any destructive action. It requires:

- the current projection to be `archive_ready`;
- the same current task generation, job, repository/PR, finalize attempt,
  head SHA, and head generation in the journal and registry;
- a terminal babysitter job with no live claim and no newer task generation;
- `worktree.yml` to name the exact canonical `<worktree-root>/<slug>` path and
  the branch stored on the current job.

It removes only a Git-registered task worktree, strictly prunes worktree
metadata, deletes only the exact local branch, and then appends one
`cleanup_completed` journal event referencing the current `archive_ready`
event. An unregistered existing path, mismatched pointer, branch checked out
elsewhere, corrupt registry, or filesystem/Git failure remains a retryable
`9-done` error.

Missing resources are treated as already completed steps, so crashes after
the stage move, worktree removal, or branch deletion converge on retry. The
`<!-- COMPLETE -->` marker is written only after the cleanup receipt is
durable. `hive archive` at an already-moved task repairs a missing receipt
before becoming the terminal no-op.

The retained remote branch is intentionally outside cleanup scope.

## Backlinks

- [[stages/finalize]] · [[stages/execute]]
- [[modules/worktree]] · [[modules/markers]] · [[state-model]]
