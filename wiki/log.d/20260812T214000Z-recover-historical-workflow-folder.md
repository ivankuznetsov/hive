---
title: Recover historical managed workflow stages by canonical folder
date: 2026-08-12
---

Recovery now reuses the canonical task folder already resolved by status instead
of rediscovering a task solely through the current workflow stage catalogue.
This keeps immutable historical managed-workflow generations recoverable after
their stage names leave current packages while retaining TaskResolver's project
and stage identity checks. A focused coordinator regression test pins the folder
handoff.
