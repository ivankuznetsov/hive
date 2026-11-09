---
title: Query manual recovery without a scheduler snapshot
date: 2026-11-08
---

Operational status now projects operator-owned manual recovery directly from
bounded task-scoped request/attempt evidence. Markerless cleared requests expose
fresh revision-bound retry actions. Pending manual work is blocked rather than
promising a queued dispatcher; verified live attempts retain agent ownership.
Projection remains read-only. Daemon receipt projection uses actual dispatch
configuration while admission retains the action-recovery carve-out.

Focused status, coordinator, dispatcher, action, authority and real-admission
integration suites passed: 634 tests and 2,742 assertions. Schema validation and
before/after request/file equality pin read-only projection of a stranded retry.
