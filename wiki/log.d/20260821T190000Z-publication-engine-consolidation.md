## 2026-08-21 — Publication engine consolidation

- Made `Hive::GithubPublication` the only branch/pull-request publication
  engine for coding Open PR and Patrol Fix Publish.
- Reduced Open PR's agent contract to authoring `pr-draft.json`; the controller
  now owns branch inventory, push, create/adoption, durable state, `pr.md`, and
  terminal markers.
- Scoped GitHub inventory to the exact head branch and added safe retry for a
  failed absent-branch push and definite PR-create failure while retaining
  reconciliation-only handling for unknown outcomes.
- Removed ordinary Patrol's fixer, candidate selector, PR opener, review
  handoff, dismissal reconciliation, and their tests. Accepted findings now go
  directly to the Patrol Fix source outbox.
- Removed Architecture Patrol's action scheduler/hook, action runner, fixer, PR
  opener, issue filer, issue/PR publication gateway methods, action transition
  facades, canonical action catalog, semantic-family machinery, family store,
  and their tests. Completed discovery now terminates after publishing
  accepted dispositions to Patrol Fix; fresh init writes discovery only.
- Narrowed both first-party discovery modules so they no longer request GitHub,
  network, or review-task mutation grants.
