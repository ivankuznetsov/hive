---
title: Bind workflow lifecycle mutations to the reviewed selection
created: 2026-07-19T00:10:00Z
tags: [workflow, honeycomb, concurrency, consent, web]
---

- Added source-commit and manifest-digest baseline checks for update/remove
  callers that apply a previously reviewed dry-run.
- Rechecked removal baselines inside the workflow mutation lock and taught
  activation to distinguish no guard from an explicit still-unselected guard.
- Bound first install activation to the selection observed after package
  validation, preventing a concurrent install/update from being overwritten.
- Added command/store regressions for stale update, stale removal, and a
  selection appearing between validation and activation.
