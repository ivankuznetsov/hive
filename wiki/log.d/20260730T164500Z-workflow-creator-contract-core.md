---
title: Isolate the workflow-creator contract and atomic evidence core
type: change
created: 2026-07-30
tags: [agent-skills, openclaw, evidence, release-proof, architecture]
---

- Moved workflow-creator constants and validation out of the generic live-agent
  proof facade. Attestation and verification now delegate to the same strict
  schema-v1 contract.
- Added an owner-private atomic evidence store that writes and fsyncs a unique
  sibling temporary, publishes initialization with a no-clobber hard link,
  renames validated replacements, fsyncs the parent directory, and cleans
  interrupted temporaries without overwriting a concurrent winner or
  truncating the prior valid receipt.
- Bound the executed research instruction to its authored path, SHA-256, and
  integer byte size. The exact retained bundle additionally binds candidate and
  OpenClaw installed manifests plus an execution receipt whose commands,
  effects, containment, teardown, and cleanup must agree with the creator row.
- Added both creator collaborators to the release builder's live and
  source-reconstructed identity and changed the hosted handoff to transport the
  evidence directory.
- Kept this U1 foundation non-claiming. The temporary producer persists an
  uploadable failure while real execution custody and authenticated
  orchestration remain the open release work recorded in [[gaps]].
