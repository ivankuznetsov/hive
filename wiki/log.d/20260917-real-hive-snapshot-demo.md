---
title: Real Hive snapshot demo
type: log
date: 2026-09-17
tags: [demo, web, snapshot]
---

# Real Hive snapshot demo

Replaced the fictional Notebook demo with a saved real Hive workspace.
`demo/snapshot/selection.json` is the reviewed corpus allowlist; the checked-in
dataset contains ten completed feature stories with merged public PRs, two
genuinely unfinished tasks with their recorded questions, the installed
`architecture@1.0.4` Honeycomb package with permissions, selected Patrol
evidence, the persisted 2026-09-15 digest, and five public repositories.

- `demo/script/capture_snapshot.mjs` captures read-only native projections,
  verifies merge evidence through the public GitHub API, applies explicit
  redactions, and fails closed; `demo/script/audit_snapshot.mjs` re-audits the
  checked-in dataset. Neither runs in CI or during a build.
- `web/script/support/demo/` renders adapted real templates into a canonical
  path-based route graph (263 routes) with a structural allowlist; live helpers
  raise instead of executing.
- `demo/src/app.mjs` now only initializes the waitlist and explains saved-state
  actions; navigation is ordinary static links, so deep links, reload, and
  Back/Forward work without client routing.
- Tests: `web/test/integration/demo_export_test.rb` (export, links, hardening),
  `demo/test/snapshot.test.mjs` (selection/audit/dataset), and
  `demo/test/browser/demo.test.mjs` (six visitor flows, mobile, waitlist).
- Deployment to hivedev.ai remains an operator-gated step; the current Worker
  version stays the rollback authority.
