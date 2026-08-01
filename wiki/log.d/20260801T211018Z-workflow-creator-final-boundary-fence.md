---
title: Workflow creator closes its raw publication and process identity edges
type: architecture
tags: [openclaw, proof, component-boundaries, evidence, concurrency]
---

`WorkflowCreatorAtomicFile` is now a private Workflow Creator Proof collaborator
and the component catalogue construction-fences it to the sole typed writer,
`WorkflowCreatorEvidence`. Identical concurrent initializers both report success
only after exact inode, one-link byte, held-directory durability, and public
binding checks. Prefix-matching recovery candidates are opened nonblocking, so
a planted FIFO is rejected without stalling recovery.

The two ordered outer model-loop receipts now bind the workflow-creation and
authorized-work roles to their corresponding U1 prompt digests and require
distinct argv digests. A duplicated process receipt therefore cannot satisfy
both roles. These remain schema obligations for U14 and U15 rather than an
execution subsystem in U1; see [[component-boundaries]], [[testing]], and
[[gaps]].
