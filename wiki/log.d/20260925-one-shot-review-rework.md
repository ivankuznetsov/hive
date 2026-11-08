---
date: 2026-09-25
title: Preserve one-shot dry-run and scheduler gates
tags: [daemon, one-shot, babysitter, patrol, scheduling]
---

- Babysitter one-shots now honor project-level `babysitter.dry_run` as well as
  the CLI flag, including empty `ran` evidence and no scheduler checkpoint
  write.
- Patrol checkpoint restoration rejects malformed or inconsistent persisted
  failure counters instead of coercing them and clearing failure backoff.
- External-scheduler guidance now includes bounded cron polling and an exact
  deadline-aware transient timer example, with the required all-scope host-stop
  predicate.
