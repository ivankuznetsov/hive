---
date: 2026-07-17
title: Canonical scheduler proofs on status surfaces
---

- Added pure, generation-fenced task scheduling proofs and complete fleet task-slot accounting.
- The daemon atomically publishes a bounded scheduler heartbeat/snapshot and journals only semantic reason changes through `TaskProjection`.
- `hive status` v5 adds root `scheduler` and required-nullable task `scheduling_proof`; text, TUI, web, and bot render them without adding execution controls.
- Stopped/stale/corrupt evidence degrades explicitly; duplicate or over-capacity ownership fails closed as `accounting_inconsistent`.
- Sanitized incident replays cover Honeycomb auth, legacy policy exhaustion, provider circuit, and merge wait. Provider-routing and PR-babysitter e2e activation remains gated on #9770/#9769.
