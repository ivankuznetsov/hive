---
title: Workflow creator resolution pins publication and future custody
type: architecture
tags: [openclaw, proof, atomic-write, component-boundaries, custody]
---

The U1 Workflow Creator Proof resolution replaces path-based receipt publication
with a packaging-owned descriptor-relative publisher. It stages outside the
exact bundle root, pins and revalidates the destination directory, publishes by
`linkat` or `renameat`, verifies the resulting inode and bytes, and fails closed
when directory durability is unsupported. A hard-kill regression proves that an
orphan cannot enter the four-file bundle or prevent Attestor, Verifier, or a
clean retry.

The dedicated `workflow_creator` entry point now loads pure proof primitives,
the creator contract, the schema-only execution contract, and atomic evidence
without loading the generic builder, Attestor, or Verifier. Component-boundary
enforcement scans the declared packaging and smoke surfaces and permits only the
temporary non-claiming U1 smoke producer to construct the writer.

The retained contract now fixes the fields that U14 and U15 must populate:
candidate gateway and installed closure identity, archive and nine-command
receipts, bounded capture, outer-process containment/teardown/cleanup, OpenClaw
dependency approval, provider/HTTPS transport provenance, and credential
environment names without values. No execution, credential selection, process
launch, provider call, or live orchestration moved into U1. Those remain the
explicit [[gaps]] before a protected-main creator proof can pass; see
[[testing]] and [[component-boundaries]].
