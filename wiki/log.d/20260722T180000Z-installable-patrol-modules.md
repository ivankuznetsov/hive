---
date: 2026-07-22
slug: installable-patrol-modules
---

- Added a strict reviewed `hive-module/v1` package contract while preserving
  existing Honeycomb manifests and lifecycle commands through normalization.
- Added project-local preview-bound lifecycle state, immutable active/previous
  generations, explicit grants, activation rollback, durable module events,
  decision receipts, first-class hook attempts, and one redacted status model
  shared by CLI and Hive Web.
- Packaged Patrol and Architecture Patrol as first-party declarative modules
  around their existing engines and authoritative state stores.
- Added fail-closed adoption, non-mutating shadow comparison, evidence-gated
  mutator ownership cutover, and checkpoint-preserving rollback. The real
  legacy capture producer, gateway-bound patrol capabilities, atomic
  reservation handoff, native workflow-task admission, seven-day observation
  window, hosted CI, and PR evidence remain explicit follow-up blockers.
