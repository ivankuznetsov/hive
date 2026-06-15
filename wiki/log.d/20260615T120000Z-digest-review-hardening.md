### 2026-06-15 — Daily digest review hardening

- Gated the global digest dispatch through the concurrency controller
  (`kind: :digest`, off the task caps, at most one in flight) and added an
  in-flight backstop so a restart can't double-dispatch the same date.
- `DigestScheduler` now records an escalating failure backoff
  (`60`/`300`/`900`s) on non-zero exit and is reconfigured in place on SIGHUP
  (`digest.enabled` / `max_catchup_days` take effect within one tick).
- Collector logs dropped tasks (`git` failure / degraded `pr.md` read) instead
  of swallowing them; `pr_title` skips the boilerplate `## Summary` heading.
- `ShipTimes` uses a fixed-string (`-F`) grep; `ShippedItem#categorizer_id` is
  project-scoped so cross-project PR-number collisions keep distinct summaries.
- Shared `Hive::Digest::Categories` is the single ordered source for the
  categorizer's valid set and the renderer's section order; renderer escapes
  `)`/`\` in link targets; the runner pre-flights recipient/token before the
  paid categorizer run; `--json` derives `ok` from status.
- `digest.max_catchup_days` now accepts `0` (= unbounded) in the validator.
