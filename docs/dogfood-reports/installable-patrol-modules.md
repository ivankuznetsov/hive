---
title: Installable Patrol Modules Shadow Report
status: collecting
---

# Installable Patrol Modules shadow report

This document is the human review companion to the machine report stored per
project at `.hive-state/module-runtime/migration/report.json`.

Current delivery status: **not eligible for mutator cutover**. The code and
fixture gates are present, but no live seven-day observation window is claimed
by this commit. Fixture timestamps exercise the gate parser only and are not
accepted as operational evidence.

The daemon automatically adopts installed Patrol and Architecture Patrol
modules into one-mutator shadow mode after exact legacy children and module
attempts quiesce. Shadow decisions are written under
`.hive-state/module-runtime/migration/shadow/`; they cannot claim work, move
legacy cursors or budgets, spawn agents, or invoke side-effect gateways.

Before a reviewer runs `hive module migration report --reviewer ID --yes`, the
project must have all of the following:

- at least seven elapsed UTC days and ten comparable decisions for each module;
- one unchanged configuration digest per module;
- zero unexplained decision differences;
- zero module-side or duplicate external effects;
- the reviewed immutable catalog and source commits recorded in module status.

`hive module migration cutover --yes` records an explicit cutover request and
fences new admissions. The daemon advances the single ownership epoch only
after exact workers are quiescent and the saved report remains eligible.
`hive module migration rollback --yes` uses the same fence, restores legacy
ownership and the previous executable/configuration when present, and leaves
patrol ledgers, attempts, artifacts, checkpoints, and event high-water marks in
place.

## Live evidence to append

- Observation window (UTC): pending
- Reviewed catalog commit: pending
- Patrol source/manifest/configuration digests: pending
- Architecture Patrol source/manifest/configuration digests: pending
- Comparable decision counts: Patrol 0; Architecture Patrol 0
- Unexplained differences: pending
- Duplicate jobs/findings/issues/pull requests: pending
- Reviewer and review time: pending
- Cutover ownership epoch: not attempted
- Rollback result: not attempted
