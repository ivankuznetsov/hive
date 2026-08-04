---
title: Add bounded Patrol qualification CLI facade
type: added
date: 2026-08-04
---

- Add internal deterministic receipt and qualification migration actions that
  accept one bounded, strict UTF-8, exact-key JSON object from stdin.
- Delegate receipt construction and confirmed qualification admission to the
  existing Patrols facades and emit their existing receipt/report documents.
- Keep the facade independent of the lifecycle/store base and route
  qualification failures through the same report-v2 schema as successes.
- Reject oversized, malformed, non-object, and extra-key requests without
  adding request files, schemas, stores, runners, or lifecycle authority.
