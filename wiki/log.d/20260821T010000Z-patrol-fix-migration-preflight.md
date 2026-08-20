---
title: Patrol Fix migration preflight inventory
date: 2026-08-21
---

- Added complete, snapshot-stable ordinary finding and Architecture v4 job
  readers that do not rely on truncated health/list projections. Missing,
  corrupt, unsupported, or changing source records remain explicit blockers.
- Added source-owned migration adapters and a source-neutral read-only core for
  semantic grouping, artifact reconciliation, exactly-one dispositions, and a
  deterministic schema-valid manifest. Different exact roots require a strict
  injected semantic decision bound to the full candidate set and current head.
- Ordinary candidates now retain strict fingerprint-ledger, live occurrence,
  patch, branch, publication-intent, PR, and review-task observations;
  Architecture candidates receive only the actions owned by their finding,
  rather than every action from the containing discovery job.
- Existing tasks, successors, issues, branches, publication intents, and
  open/draft/closed/merged PRs remain observations only; preflight plans no
  local or GitHub mutation.
- Architecture v3 runtime state remains unsupported. Migration inventories its
  regular files only as opaque paths, sizes, and raw-byte digests, leaving the
  bytes untouched and outside current v4 authority.
