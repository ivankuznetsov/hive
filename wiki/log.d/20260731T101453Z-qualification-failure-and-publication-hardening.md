---
title: Qualification failure evidence and terminal publication are fail-closed
type: architecture
date: 2026-07-31
tags: [patrol, qualification, recovery, storage]
---

Compressed Patrol qualification now treats host observation and publication as
security boundaries. Directory inventories stop at their cap while streaming,
target reads are descriptor-stable and no-follow, event verification checks the
complete canonical schedule envelope, and evidence collection no longer
constructs stores or acquires mutating locks.

A candidate process failure after spawn becomes a digest-bound, 8 KiB typed
value containing only closed phase/reason codes, process state, stream digests,
target digests, duration, and honest cleanup status. The orchestrator records
that value before preserving the exact typed failure, and the lane publishes it
as a receipt-less process row with `candidate_execution_failed`. Failures before
spawn retain the existing configuration-error contract.

Terminal lane publication prevalidates every artifact, writes and verifies one
private fixed-inventory pending tree, then installs it with an atomic
no-replace directory rename. Diagnostics are stored separately. Fault injection
after every staged write and immediately before install proves that readers see
either no terminal lane or the complete exact lane, and that retry can replace
only a verified abandoned pending tree.
