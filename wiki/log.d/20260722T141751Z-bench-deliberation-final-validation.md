---
title: Require complete benchmark deliberation verdicts
date: 2026-07-22
updated: 2026-07-22T14:17:51Z
tags: [bench, workflow, deliberation, validation, recovery]
---

The built-in benchmark judge stage now refuses `COMPLETE` when any configured
judge's preserved round-two deliberation record has a missing or invalid
`final` score. It reports `INCOMPLETE_DELIBERATION` with the exact candidate,
task, and judge instead of letting a fail-soft `final: null` flow into publish.

The retry skip-set is now derived from fully completed transcripts rather than
mere cell presence. A provider failure therefore remains visible in
`deliberation.json` but the affected cell is eligible for a later judge-stage
retry; already complete cells remain skipped. The focused workflow regression
executes both embedded Ruby guards against valid and null-final fixtures.
