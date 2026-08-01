---
title: Workflow creator initialization and retained bytes become exact
type: architecture
tags: [openclaw, proof, evidence, crash-recovery, unicode]
---

The workflow-creator initializer is now an explicit idempotent publication
state machine. A retry accepts an exact owner-private, byte-identical one-link
target as completed, repairs only the unique matching two-link target/staging
topology, removes its new retry temporary before syncing both held directories,
and rejects unrelated or ambiguous targets. Only the descriptor-relative target
collision becomes the private already-exists signal; other filesystem and I/O
failures normalize to the component error surface.

Retained bundle reads are binary and canonical comparisons use exact bytes, so
valid Unicode provider fields and installed-manifest paths pass producer,
Attestor, and Verifier parity. The lower vocabulary is recursively immutable
and fixes two ordered outer model-loop roles matching the workflow-creation and
authorized-work OpenClaw calls. U14 still owns real execution custody and U15
still owns authenticated orchestration; see [[component-boundaries]],
[[testing]], and [[gaps]].
