---
title: Dogfood retry gaps close without scheduler churn
date: 2026-07-24
tags: [daemon, attempts, recovery, bugfix]
---

# Dogfood retry gaps close without scheduler churn

The daemon now releases an `ERROR reason=attempt_lost` compatibility marker
when its durable successor lineage has ended in an unambiguous terminal
failure or cancellation. The release still requires the shared cooldown,
current worktree safety, the task lock, and an exact marker-generation match.

Previously, loss recovery stopped after admitting the first successor while
generic error recovery skipped every `attempt_lost` marker. If that successor
then failed, the task remained permanently parked even though ordinary
admission correctly treated the ancestor loss as resolved.

Live, unresolved, lost, successful, unreadable, and ambiguous successor
lineages remain fail-closed.

Architecture patrol now also treats
`daily_architecture_review_spawn_limit` as a daily boundary. Partial jobs sleep
until the next UTC day after exhausting that limit instead of launching a
short-lived child every minute.

See [[modules/attempts]], [[modules/daemon]], [[modules/patrol]], and
[[testing]].
