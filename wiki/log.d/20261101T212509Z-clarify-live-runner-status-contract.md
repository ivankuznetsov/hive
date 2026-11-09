---
title: Clarify the live-runner status contract
date: 2026-11-01
tags: [operational-status, liveness, status, documentation]
---

- Clarified that stale-runner repair requires neither liveness flag to be
  true, and named `blocker_owner` among the fields where live evidence wins.
- Kept classification and human display ordering together, separated
  liveness/PID details, and stated the stale-only null PID contract directly.
- Annotated the remaining synthetic stale-lock fixtures and removed the
  redundant reason-source assertion while retaining first-liveness-reason
  selection in the shared test helper.
