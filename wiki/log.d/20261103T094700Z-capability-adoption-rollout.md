---
date: 2026-11-03
title: Enable capability adoption after shared gate and recovery proofs
---

New coding captures now adopt execution plans with QA On by default. Retained
tasks keep their previous semantics, and disabling future adoption never clears
an accepted gate. Production-default capture tests cover the first-use notice,
missing-runner blockers and a fresh QA decision on every subsequent task.
Capability policy is project-local; legacy fixture overrides are written in
the initialized project configuration rather than ignored global settings.

The executable wrapper admits repeatable capability/approval/waiver options and
preview booleans, preserving literal text after the explicit argument boundary.
Operator docs cover per-task exceptions, installed skills, exact local security
envelopes, immutable versions and managed-update recovery.

The new required semantic E2E composes default QA with a configuration-only
verifier, admits an installed UI skill preview, records independent exact-SHA
results and rejects forced advancement after a source commit. The E2E catalog,
schema mirrors, wiki command index and generated defaults have focused guards.
Existing legacy fixtures explicitly opt out of adoption. The read-only wiki
integration guard runs the current source in an isolated repository so
concurrent development logs cannot produce false write reports.
The component boundary catalog names capability actors and ownership readers
as existing-repository consumers, retaining parent attempt reservations. The
daily digest explicitly treats their per-task journal records as internal noise;
no project QA reporting surface is added. Process cleanup also tolerates an
exited process returning `ESRCH` when its environment is read.

Local verification includes the 395-test capability/command suite, 399 Rails
tests, 25 focused Chromium system tests and the semantic capability E2E. New
library files have complete focused line coverage: 2,213 executable lines across
all 17 additions. The broad checkpoint ran 16,187 tests and found four fixture
failures: a stale rollout expectation, two invalid pre-existing capability
anchors and a task directory removed before lazy action evaluation. The affected
56-test group passes after correcting those fixtures; the other root worker's
7,515 tests and the component suite passed. No live approved security provider session was run;
kernel scope enforcement and actor lifecycle use deterministic local fixtures.
