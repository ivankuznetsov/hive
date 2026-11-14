---
title: Plan reviews in paused projects report idle, not a scheduler wait
type: change
created: 2026-11-14
updated: 2026-11-14
tags: [operational-status, plan-review, daemon, status-truth]
---

The dogfood operational snapshot (cda8a6952) listed 71 tasks as
`waiting_on_provider_or_scheduler`. 42 of them were `3-plan` rows in projects
whose daemon is disabled (`hive`, `writero`, `hive-site`, `screenote`), with
owner `hive` and reason "start a linked plan review from the current plan":
41 stale because the review policy changed after resolution, one because the
plan changed. None had a live worker, retry, or route, and no scheduler
dispatches `plan-review-run` for a paused project, so the status claimed
automation that could never happen.

- `OperationalStatus#classify` now returns `idle`/`none` for a
  `plan_reviewing`/`plan_review_retry` row in a daemon-disabled project when
  the review owner resolves to `hive` or `scheduler`
  (`paused_plan_review_automation?`). The overdue-retry repair check still
  runs first.
- `reasons_for` reports `plan_review_dispatch_disabled` (source `scheduler`)
  with the review's required action and the exact
  `hive plan-review-run SLUG --project NAME` command.
- Provider-, agent-, and operator-owned review waits in paused projects keep
  their existing classification.

Tests: `test/unit/operational_status_test.rb` covers the paused hive/scheduler
owners, the daemon-enabled contrast, the reason text, and the summary counts.
