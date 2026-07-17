---
title: 8-finalize stage
type: stage
source: lib/hive/stages/finalize.rb, lib/hive/finalization/, templates/finalize_prompt.md.erb, templates/finalize_summary.md.erb
created: 2026-05-13
updated: 2026-07-17
tags: [stage, finalize, pr, github, babysitter, journal]
---

**TLDR**: Finalize prepares the existing PR, then durably transfers ownership
to one generation-scoped babysitter job. The task remains visible in
`8-finalize` while that job watches the exact PR. `summary.md`, a complete
marker, green checks, merge readiness, and disappearance from the open-PR list
never authorize archive.

## Durable handoff

Before reporting success, `Stages::Finalize`:

1. Resolves an exact `Hive::Gh::PrSnapshot` with canonical repository, PR URL
   and number, state, and head SHA.
2. Reserves or attaches the deterministic job in
   `.hive-state/babysitter/jobs/`. A reservation is inactive and unclaimable.
3. Appends a deterministic `finalized` event, or
   `finalize_attempt_adopted` for a fresh retry attempt, to the authoritative
   task journal.
4. Activates the job only after the matching journal event exists and verifies
   journal/registry agreement.
5. Writes or repairs `summary.md` as presentation.

The stable job identity includes project, task identity, `task_generation`,
canonical repository, and PR number. A new finalize attempt adopts the same
job and same-head evidence; it does not create a second owner. Replacing a PR
requires exact `CLOSED` or `INVALID` proof for the old PR and preserves both
job records.

An existing `summary.md` is a retry signal, not an idempotency authority. A
retry repairs the handoff without reopening, pushing, or retargeting the PR.
An already-merged PR also gets a normal handoff: finalize never writes
`merged`; the babysitter must record an exact `MERGED` snapshot.

## Ownership boundary

Finalize may perform its existing clean-exit, push, PR-body, secret-scan, and
ready-for-review work before the handoff. Once the handoff is journal-backed
and active, branch mutation belongs exclusively to the claimed babysitter job.
The task worktree remains retained read-only recovery state until
`archive_ready` and [[stages/done]] cleanup.

The normal projected lifecycle is:

`finalized -> babysitter_active -> merge_ready -> merged -> archive_ready`

Any exact head change increments `head_generation`, invalidates prior
readiness, and returns the same job to `babysitter_active`. `CLOSED` without
`merged_at` is a visible blocker, never terminal success.

## Exceptional no-PR outcomes

`hive finalize-outcome TARGET approve` is the only supported no-PR terminal
path. It is local-TTY-only, requires an exact confirmation plus a reason, and
validates typed evidence for `abandonment`, `superseded`, or `direct_landing`.
The journal records OS actor identity and evidence. `rearm` appends history and
reactivates watching before archive; it never edits the approval.

## Archive gate

`Hive::Finalization::Reconciler` is the only writer of `archive_ready`. It
derives that event from current-generation explicit `merged` evidence or a
current approved no-PR event. Generic `--force`, terminal markers, and direct
GitHub reads cannot cross the `8-finalize -> 9-done` transition guard.

Legacy finalized tasks with a summary but no journal handoff remain
non-archivable and expose `rerun_finalize`; rerunning establishes the job
without post-transfer branch mutation.

## Backlinks

- [[stages/open-pr]] · [[stages/review]] · [[stages/done]]
- [[modules/babysitter]] · [[modules/daemon]] · [[state-model]]
