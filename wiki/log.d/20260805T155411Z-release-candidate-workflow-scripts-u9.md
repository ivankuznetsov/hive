---
title: Bound release-candidate workflow control scripts
type: change
module: release-candidate
created: 2026-08-05
tags: [release-candidate, workflow, architecture]
---

The protected release-candidate workflow now delegates dispatch/retry
validation and attestation input collection to three small committed shell
scripts. The protected-main bootstrap, candidate and platform execution,
aggregate construction, and checkout-free Check publisher remain inline. The
workflow verifies the archived validator against the exact trusted commit, and
candidate tool identity now covers all three scripts without changing job
names, permissions, dependencies, matrices, artifacts, or release authority.

Post-U8 campaign `31014105054` and named retry `31015265841` are recorded as
dogfood evidence: the retry selected exactly one gate and reused the immutable
predecessor candidate artifact, while known harness findings kept both runs
`qa_blocked`. No tag, publication, deployment, or release action occurred.
