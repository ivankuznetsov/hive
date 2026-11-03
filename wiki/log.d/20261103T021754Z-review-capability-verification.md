---
date: 2026-11-03
slug: review-capability-verification
---

- Added immutable check results and accepted-chain projections binding task,
  parent attempt/spawn, execution plan, evaluated revision, runner configuration
  and environment. Generic command and actor adapters support configured
  verifiers alongside QA; QA additionally needs a passed behavior check or a
  visible scoped operator waiver.
- Review evaluates adopted checks at completion and on complete-marker retries,
  imports only matching clean local CI, and gives direct callers durable recovery.
  Existing tasks keep their CI-skip and browser-soft-warning behavior.
- Reused OutcomeEvidence proof validation/materialization and exact detached Git
  snapshots. Missing runners and rejected proposals block; real failed checks
  retain actionable stable findings. Optional missing visual capture does not
  discard other usable proof. The adoption switch remains disabled pending gates
  and operator controls; live provider/browser scope proof remains a documented gap.
