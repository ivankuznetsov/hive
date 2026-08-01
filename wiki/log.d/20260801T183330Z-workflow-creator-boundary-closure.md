---
title: Workflow creator proof declares and binds its retained closure
type: architecture
tags: [openclaw, proof, component-boundaries, evidence, custody]
---

The packaging-owned Workflow Creator Proof is now a guarded component in
`config/component-boundaries.yml`. Its catalog row assigns schema validation to
`WorkflowCreatorContract` and `WorkflowCreatorBundle`, assigns primary-receipt
mutation only to `WorkflowCreatorEvidence`, and keeps execution, credentials,
providers, and live orchestration outside U1.

Candidate and OpenClaw installed manifests now retain distinct executable,
interpreter-or-launcher, package, and lock records. Every required record must
also occur byte-for-byte in the bounded inventory, and a canonical closure
digest plus package/lock digest and size cross-bind that inventory to the
claimed installation identity. Focused tests reject missing, duplicated,
unlisted, or identity-drifted members and simulate interruption during a
partial temporary write. Exact execution custody remains the U14 gap and
authenticated provider orchestration remains U15; see [[testing]] and
[[gaps]].
