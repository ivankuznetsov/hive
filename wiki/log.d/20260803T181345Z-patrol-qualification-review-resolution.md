---
title: Tighten Patrol qualification and report-v2 transitions
type: changed
date: 2026-08-03
---

- Bind verification to the exact evidence receipt and reject conflicting
  capture/occurrence wrappers, unsettled effects, and cross-lane configuration
  drift while preserving explicit replay telemetry.
- Compose the evidence-receipt schema from the strict U2 values and bound
  receipt collections before mapping.
- Enforce monotonic report-v2 CAS transitions, require two fresh lanes after
  invalidation, restore admissions after interrupted stable upgrades, and keep
  report-v2 cutover behind its separately authorized lifecycle boundary.
