---
title: Bound reduced U3c to installed and provider custody smoke
date: 2026-08-05
category: architecture
module: patrol
tags: [patrol, qualification, installed-live, threat-model, u3c]
---

**Decision:** Documented the proposed reduced U3c threat model and five-owner
packaging boundary. Because merged U3b uses prepared records, U3c may claim only
`installed_live_smoke_verified` after a protected-main controller evaluates a
distinct later candidate and proves exact installed candidate, both-module,
sandbox/process/resource, artifact, and separate provider-transport custody.
The infrastructure PR cannot qualify itself. The result cannot populate report
v2's `installed_live` lane or emit `evidence_ready_for_operator`.

**Gap:** The fresh both-module scheduler/fault matrix, independent controls,
provider-backed Patrol decisions, credential-expiry/quota-reset lifecycle, and
the inherited `U3-I06` / `U3-ARCH-006` obligations remain deferred until an
observed defect or explicit operator readmission justifies that architecture.
Production mutation remains forbidden until independent security acceptance
and explicit operator signoff on the reduced claim.
