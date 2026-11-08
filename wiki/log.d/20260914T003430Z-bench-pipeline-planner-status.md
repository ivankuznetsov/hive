---
title: Validate the bench planner spawn before executing its plan
date: 2026-09-14
---

Ordinary patrol flagged that the packaged bench `Pipeline` inferred planner
success solely from provider-limit text and plan-file emptiness. A planner
spawn killed at the wall clock or exiting non-zero could still leave a
non-empty `HIVE_BENCH_PLAN.md`, and `Pipeline#call` then fed that partial plan
to the executor and returned a cell scored as `generated`. The pipeline now
validates the planner spawn status before the executor phase: any non-`:ok`
planner exit returns a `plan_failed` cell ("planner timed out" / "planner
exited non-zero") with no diff, so a truncated plan is never scored as a clean
generation. Regression tests load the harness from its packaged home and pin
the timeout, non-zero, empty-plan, provider-limit, and happy-path statuses.
