---
title: Bring workflow discovery and reviewed lifecycle operations to Hive Web
created: 2026-07-19T00:30:00Z
tags: [web, workflow, honeycomb, consent, browser]
---

- Added a primary Workflows surface with project-scoped built-in, authored,
  managed selected/retained, integrity, provenance, and default-workflow state.
- Added real owner-authored template scaffolding and links to choose the project
  default.
- Added install/update/remove preview pages backed by the CLI dry-runs, expiring
  signed receipts, exact candidate/selection identity checks, ordinary consent,
  and separate security-escalation consent.
- Kept the legacy Honeycomb publisher limitation explicit instead of exposing a
  browser action that would open an unusable v2 registry PR.
- Added Rails request/model coverage and Playwright paths for real scaffolding
  plus permission-reviewed install; live desktop/mobile dogfood found and fixed
  the five-item mobile navigation squeeze with a full-width second nav row.
