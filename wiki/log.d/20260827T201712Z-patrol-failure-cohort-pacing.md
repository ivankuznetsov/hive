---
title: Durable Patrol failure-cohort pacing
module: attempts
tags: [attempts, patrol-fix, daemon, recovery]
---

Patrol attempt admission now records receipt-bound typed failures in a bounded
UTC decision shard keyed by project, stage, failure code, and runtime digest.
Three matching failures open a one-hour circuit; only one fenced probe can run,
including an early probe claimed by an explicit operator recovery. Success
closes the cohort, while a changed runtime build digest or UTC rollover starts
open. Finalization consumes terminal evidence before removing the hot record;
failed pre-persistence and definitively unstarted handoffs release only their
matching probe fence.

Attempts capacity remains the shared daemon safety boundary. Patrol scheduling
continues to use its separate scan concurrency and per-engine discovery
allowances; this change does not reserve or partition task capacity. Circuit
pacing reports `failure_cohort_cooldown`. Focused tests cover restart
persistence, concurrent single-probe claiming, explicit release, repair and
rollover release, failed probe reopening, daemon admission reasons, and the
sanitized 600-charge incident fixture. The runtime digest excludes
deployment-only identity, and hard-cap reasons retain precedence over cohort
pacing.

The installed-daemon representative-load and complete UTC-window proof remains
an explicit follow-up in [[gaps]].
