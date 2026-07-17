---
title: Durable finalization babysitter watching
date: 2026-07-17
tags: [finalize, babysitter, journal, archive, status]
---

- Turned finalize into an idempotent handoff to one canonical, durable
  babysitter job with inactive reservation, journal-backed activation,
  attempt adoption, expiring claims, and monotonic fences.
- Added exact PR/head observation, stale-head invalidation, explicit `MERGED`
  evidence, closed-unmerged blockers, and reconciliation-only
  `archive_ready`; discovery and telemetry remain non-authoritative.
- Added TTY-confirmed audited no-PR outcomes with append-only re-arm and
  fail-closed evidence validation.
- Published the bounded status v6 finalization object across text/JSON, TUI,
  hivebox, and Telegram without renderer-side repair or network calls.
- Made Done remove only the validated local task worktree and branch after
  archive eligibility, with crash-resumable idempotency and a durable cleanup
  receipt.
- Added the sanitized offline TopGreenDeals PR 295 replay, pinning restart,
  takeover, stale-head reset, disappearance/closed negative cases, explicit
  merge at `2026-07-16T23:05:50Z`, and exactly-once archive/cleanup.
