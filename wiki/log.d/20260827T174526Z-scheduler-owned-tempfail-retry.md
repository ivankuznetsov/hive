---
title: Durable TEMPFAIL receipts become scheduler-owned retries
type: change
date: 2026-08-27
tags: [attempts, daemon, patrol-fix, conditions, retry]
---

- Added a point-addressed latest-terminal index so retry admission can resolve
  an exit-75 receipt after finalization moves the attempt to permanent proof.
- Fresh requests for the same task generation wait for
  `daemon.transient_retry_backoff_sec`; no retry watcher or historical scan is
  involved, and the daily attempt charge remains refunded.
- Projected execute health keeps TEMPFAIL pending under scheduler ownership,
  and Patrol status no longer reports its synthesized non-zero exit as a fix
  agent failure.
