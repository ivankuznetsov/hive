---
title: Separate Patrol diagnostics from release qualification
type: change
created: 2026-07-31
tags: [patrol, qualification, e2e, release, security]
---

- Local same-candidate and deterministic-only Patrol evidence now belongs to
  an explicitly runnable advisory coverage ID.
- Required release coverage accepts only an `evidence_ready_for_operator`
  result with no blockers, an independent protected-main
  `trusted_remote` control, and both lanes passed.
- Focused harness regressions reject both previously accepted weak outcomes
  from the required path while retaining them as diagnostic evidence.
