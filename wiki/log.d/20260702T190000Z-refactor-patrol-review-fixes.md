---
title: Refactor patrol review fixes
date: 2026-07-02T19:00:00Z
tags: [command, refactor-patrol, decision]
---

Review-fix pass on [[commands/refactor-patrol]]:

- **Dry-run is now truly non-persistent.** `--dry-run` no longer creates
  `.hive-state/refactor_patrol/` (the command skips `state.ensure!`), the
  reviewer scratches agent output in a temp dir, and it writes no thesis JSON
  or run-error logs. Previously only `persist`/`update_scan_state` were guarded.
- **Leverage ranking is deterministic (R5).** The reviewer discards the agent's
  `expected_leverage.score`/`breakdown` and stamps the computed churn/fan-in/
  complexity/coupling blend, so ranking is always explained by measured signals.
  The agent estimate is advisory only.
- **Behaviour-preservation guidance is required for every admissible thesis
  (R8).** Test-rich slices with empty validation commands get the configured
  `test` command injected; otherwise `characterization_first` is forced.
- **Evidence without a file path is flagged, not dropped.** The thesis schema no
  longer requires `evidence[].file`, so a no-path evidence item is returned as
  `admissible: false` instead of failing schema validation and silently pinning
  `last_scanned_sha`.
- **Leverage tolerates binary/non-UTF-8 files** (scrubbed on read), memoizes
  `tracked_files`/`fan_in`, and honours `refactor_patrol.exclude` globs.
- `Caps` no longer false-positives `cross_feature_impact` on a feature's own
  entrypoints; the review prompt fences repo-derived context in a per-spawn
  `user_supplied` block.
