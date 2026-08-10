---
date: 2026-08-10
summary: Add the explicit provider-routing policy boundary
---

- Added an opt-in global provider-account registry and per-stage ordered
  `routing.pool` policy with strict account/model pins and hard compatibility
  requirements.
- Added immutable account, route, policy, request, decision, pin, requirement,
  and configuration values plus a canonical credential-free policy digest.
- Reused candidate-specific `Hive::ModelRouting` precedence without changing
  the implementation-identity meaning of provider (adapter/profile).
- Kept stages without a pool on a structural legacy bypass that does not read
  provider accounts, health, or capacity.
- Added a fail-closed sanitized provenance inventory for Claude, Codex, Pi,
  and Grok; no failure class is trusted for shared scope until a reviewed real
  capture establishes stable provenance.
