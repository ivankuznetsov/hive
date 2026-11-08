# 2026-10-02 — Stale metadata updates preserve deleted tasks

- Update-only task metadata operations now retain a transient observation of
  the original directory and stable task identity. Missing tasks and copied
  same-path replacements return a stale result instead of recreating or
  mutating a folder; explicit creation and restoration remain separate APIs.
- Display-name generation, plan-review requirements, plan dependency adoption,
  managed-workflow pin migration, completion clocks, and automatic rollback
  now carry that observation through their existing lifecycle custody and gate
  commits, counts, notifications, or restaging on an applied update.
- Deterministic regressions delete or replace tasks before custody, after the
  metadata read, and immediately before persistence. The supported drop path
  remains serialized by project commit lock before non-creating task leases.
