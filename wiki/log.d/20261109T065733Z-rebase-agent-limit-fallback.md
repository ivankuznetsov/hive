## 2026-11-09 — Rebase conflict agent honours review.limit_fallback

- Symptom: during a 6-review run, the auto-rebase conflict-resolution agent
  hit `limits reached for codex ... try again at Nov 11th`; the rebase aborted
  as `agent_failed` and review continued on a stale base, even though
  `review.limit_fallback` mapped `codex: claude` for every other review role.
- Change: `Hive::Rebase#conflict_agent_limit_fallback` reuses
  `Review::LimitFallback.decide` / `.record!` (phase `rebase`, role
  `rebase conflict resolution`) when the task's current stage runs the review
  runner. An approved substitute re-dispatches the conflict agent once on the
  fallback profile (`rebase_conflict-fallback-<agent>` log label, default
  model); a failed substitute keeps the primary's limit result.
- `LimitFallback.outcome` now owns the used/limited/failed classification;
  the review and CI-fix helpers delegate to it.
- Pages: [[modules/rebase]], [[stages/review]], [[modules/config]], [[gaps]].
