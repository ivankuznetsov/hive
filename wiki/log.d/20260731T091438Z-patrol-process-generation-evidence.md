---
title: Patrol qualification owns process-generation recovery evidence
type: architecture
date: 2026-07-31
tags: [patrol, qualification, recovery, e2e]
---

The compressed Patrol qualification lane now supervises one full candidate
process per recovery generation over one case sandbox and `HIVE_HOME`. The host
accepts private status 76 only at the checkpoint named by the immutable
generation request, requires stable process-target identity, verifies
production records without advancing them, captures bounded before/after
snapshots, and chains request, process, checkpoint, state, and output evidence
through generation receipts.

Candidate Actuals no longer contain the fault checkpoint, state digests,
recovery trace, restart generation, or decision class. The oracle attaches
those values from host evidence only. Reconciliation-conflict recovery is a
three-generation internal host plan rather than a public fault, and unexpected
process outcomes remain in failed-lane artifacts even when the host cannot
issue a generation receipt.
