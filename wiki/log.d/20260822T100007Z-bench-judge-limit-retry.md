---
title: Retry provider-limited benchmark judges before deliberation
date: 2026-08-22
tags: [bench, judge, provider-limit, recovery, deliberation]
---

The packaged bench judge stage now validates the complete configured judge
slate immediately after fail-soft rejudge and before starting adversarial
deliberation. Rejudge emits structured failure evidence keyed to the exact
task, candidate, and judge. A missing or undersampled judge writes a canonical
`ERROR reason=limits_reached retry_after=...` marker, allowing the daemon's
bounded cooldown healer to restart the stage automatically only when every
incomplete judge instance has matching quota evidence. Structural,
reasoning-effort, unexpected-cell, unmatched, mixed, and non-quota failures
remain operator-owned `WAITING` states.

`HiveBench::JudgeSlate` owns both result-slate checks so pre-deliberation and
final validation cannot drift. Judge adapters now type provider limits from
trusted stderr or HTTP status evidence before rejudge emits the structured
event; model-authored output cannot forge quota proof. The typed error retains
the canonical `limits_reached` prefix so generation-time all-judge failure
classification remains backward compatible. Retry markers relocate
to EOF atomically so accumulated diagnostics cannot push the current marker
outside Hive's bounded scan. The stage checks the installed snapshot's retry
capability and directs operators to refresh an older pinned runtime before it
loads the new gate.

Regression coverage proves quota, mixed, undersampled, effort, malformed-event,
missing-cell, and unexpected-cell classification; full-slate admission before
deliberation; old-runtime guidance; typed provider evidence; and canonical
marker identity beyond the 1 MiB scan window.
