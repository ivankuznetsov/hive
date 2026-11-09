## 2026-11-08 — Strengthen proposal tracking verification

Proposal lifecycle integration now admits real tasks through the production
`Attempts::Entrypoint` and `Attempts::Dispatcher` composition before producing
proposal sources. A static dependency fence over the proposal subsystem replaces
synthetic active-store snapshots and prevents proposal code from depending on
active skill or workflow mutation surfaces. Daily-digest coverage also names
both proposal activity kinds explicitly as noise.

**Verification:** Focused proposal-tracking integration and daily-digest
materiality tests.
