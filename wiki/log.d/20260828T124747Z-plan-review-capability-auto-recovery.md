---
date: 2026-08-28
tags: [plan-review, daemon, grok, markers, recovery]
pages: [modules/plan_review, stages/plan]
---

# Required plan review now owns completion and capability recovery

A planner-authored `COMPLETE` marker is now reconciled to `WAITING` whenever
the required review projection still denies execution. The same reconciliation
runs during daemon review automation, so legacy rows cannot keep advertising a
complete plan while required coverage is missing. Guarded plan approval still
owns the final `WAITING` to `COMPLETE` transition immediately before develop.

Mandatory reviews now retain successful reviewer legs and reset only an
unsupported primary or adversarial leg. After three identical immediate
capability probes, Hive schedules another probe every five minutes instead of
terminally parking the review. Identical misses update one rolling compact
receipt per role without copying `plan.md`, appending routes, or creating full
attempt artifacts; Hive creates the next immutable attempt only after the
launcher and adapter capability checks report present. Legacy blocked
projections with a persisted unsupported initial route are daemon-runnable
under the new behavior, allowing a repaired Grok binary or reviewer skill to
heal the existing review lineage without an operator-created review or plan
generation. A successful Grok attempt recorded before Hive recognized the
`grok-4.6-build` served-model alias also receives one versioned rerun under the
current identity contract; the new attempt can earn adversarial coverage while
the original immutable receipt remains intact.
