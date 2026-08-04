---
title: Add opt-in Patrol public-process qualification
type: change
date: 2026-08-04
tags: [patrol, architecture-patrol, e2e, qualification]
---

- Added a clean-candidate, opt-in U3b campaign that obtains twenty Patrol
  comparisons through real CLI and owned daemon processes.
- Kept the campaign outside default tests, E2E, coverage, and hosted CI; only
  its small collector and provider-boundary contracts run normally.
- Kept expected receipt construction test-owned and hash-only, then required
  exact agreement from the production U3a receipt and admission facades.
- Kept report-v2 conversion on its daemon-owned path with one final bounded
  daemon generation; the campaign remains entirely opt-in.
- Allocated collision-free ordinary schedule windows with intervals longer
  than the bounded run so daemon generations cannot depend on wall-clock
  coincidences or turn a later negative case due.
- Restored the missing `Attempts::API#dispatch_module_hook` delegation exposed
  by the real daemon run, so module events reach the configured durable-attempt
  adapter instead of failing at the facade.
- Kept semantic duplicate detection for externally observable effects while
  treating distinct `job`, `discovery`, and `action` receipts as local
  JobStore transitions. Their intent and idempotency identities still detect
  replay, but a fenced recovery generation no longer looks like a duplicate
  remote side effect.
