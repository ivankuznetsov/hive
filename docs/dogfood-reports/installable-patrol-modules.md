---
title: Installable Patrol Modules Shadow Report
status: blocked-not-delivery-evidence
---

# Installable Patrol Modules shadow report

This document is the human review companion to the machine report stored per
project at `.hive-state/module-runtime/migration/report.json`.

Current delivery status: **hard-blocked and not delivery evidence**. No live
seven-day observation window, cutover drill, rollback drill, hosted exact-head
CI proof, or reviewed non-draft merge-ready PR is claimed by this commit.
Fixture timestamps exercise the gate parser only and are not accepted as
operational evidence.

The daemon can adopt installed Patrol and Architecture Patrol modules into
one-mutator shadow mode after exact legacy children and module attempts
quiesce. Module-side shadow decisions are written under
`.hive-state/module-runtime/migration/shadow/`; they cannot claim work, move
legacy cursors or budgets, spawn agents, or invoke side-effect gateways.
Comparison is admitted only when the trigger carries a separately persisted
`legacy_mutator_capture`; missing captures remain non-comparable.

Current source gives ordinary scheduler reservations an immutable typed capture
and gives Architecture Patrol a linked finalized scheduler capture in addition
to merge enqueue provenance. Separate ordinary/architecture effect gateways
wrap state, finding, attempt, branch, issue, PR, and review-handoff sinks with
live owner/config/capability checks. Their append-only receipts are observation,
while StateStore, JobStore, ReviewHandoff, and the Safe Agent Git Gate retain
recovery authority. This document still contains no qualifying live
occurrences, compressed fault campaign, cutover drill, or hosted delivery
proof. Those remaining gates mean this report must not be used to request
cutover. Machine eligibility
remains false until current evidence is rebuilt and re-reviewed; cutover
re-evaluates the live shadow directory rather than trusting this document or a
saved `eligible` bit.

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
- Hosted exact-head required checks: not captured
- PR review/draft/mergeability/auto-merge state: not captured
