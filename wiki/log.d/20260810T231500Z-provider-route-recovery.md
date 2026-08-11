---
date: 2026-08-10
title: Hand provider routing outcomes to durable recovery
---

- Added dispatch-request v5 with a strict marker/markerless recovery union,
  immutable provider terminal-receipt identity, and bounded route-decision
  observations.
- Made provider-health acknowledgement a hard barrier before failed-route
  redispatch and admitted the retry as an ordinary same-generation successor.
- Kept initial and later route exhaustion on one `RecoveryCoordinator`
  lifecycle and retry charge; all-route provider capacity remains neutral and
  creates no deadline or recovery request.
- Wired the production daemon through runtime finalization maintenance so the
  provider-health consumer runs before explicit terminal attempts can archive.
