---
title: Workflow creator review closes dependency and crash-recovery gaps
type: architecture
tags: [openclaw, proof, component-boundaries, evidence, crash-recovery]
---

The U1 Workflow Creator Proof now shares prompt, command, process-role,
containment, cleanup, and receipt constants through a lower vocabulary leaf.
The execution receipt validator no longer loads or refers back to the creator
contract or bundle validator, and component enforcement now resolves
repository-relative packaging requires and scans the complete packaging tree
for unauthorized evidence-writer construction.

The descriptor-relative initializer recovers only the unique crash topology in
which the target and one staging name are hard links to the same expected
mode-`0600` inode and bytes. It removes the staging link, verifies the resulting
one-link target, and syncs both held directories; ambiguity fails closed.
Canonical closure records are insertion-order independent, exact non-ASCII
bytes round-trip safely, UTF-8 failure details truncate only at valid byte
boundaries, and public storage failures normalize to the proof error surface.

The local success writer requires a mode-`0700` bundle root and four mode-`0600`
regular files. Hosted artifacts normalize Unix modes, so Attestor and Verifier
retain their owner/type/no-follow/link-count/identity/content checks without an
archive-only transport subsystem. U14 execution custody and U15 authenticated
orchestration remain non-passing gaps; see [[component-boundaries]], [[testing]],
and [[gaps]].
