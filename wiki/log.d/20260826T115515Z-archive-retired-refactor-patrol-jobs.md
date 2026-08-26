---
title: Archive retired Architecture Patrol action jobs
type: change
created: 2026-08-26
tags: [refactor-patrol, patrol-fix, archive]
---

Added an explicit `hive refactor-patrol PROJECT --archive JOB_ID` transition
for authority-revoked action-era jobs whose findings have moved to Patrol Fix.
It fails closed around live or remotely continuing work, retains the full job
ledger, and emits the existing bounded job-detail projection after completion.
