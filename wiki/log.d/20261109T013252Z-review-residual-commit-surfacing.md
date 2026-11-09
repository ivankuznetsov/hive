## 2026-11-09 — Review surfaces unpublished residual commits after agent failures

- Symptom (PR #1419): the Codex CI-fix agent hit its usage limit
  (`REVIEW_ERROR phase=ci reason=limits_reached retry_after=2026-11-11`). The
  stage-exit CleanExit then committed the agent's leftover edits as
  `5c7fb43e02 chore(6-review): commit residual worktree changes`. That commit
  held valid coverage tests and a flake fix, but nothing pushed or reported it,
  so the PR stayed red.
- Fix: `Hive::ReviewResidualCommit.annotate!` (called from
  `Base#enforce_clean_exit!` on a 6-review auto-commit) compare-and-swaps the
  failure marker (`REVIEW_ERROR`/`REVIEW_STALE`/`REVIEW_CI_STALE`/`ERROR`) to
  add `residual_commit=<sha> residual_published=false` and a `message=` note.
  New `Hive::Markers.merge_attrs_if_current` keeps every existing attr.
  `hive run` text and JSON next-step say to inspect the commit, then either
  re-run review (which reviews and publishes it through the guarded path) or
  drop it with `git reset --keep <sha>^`. Hive does not auto-publish it because
  the residue skipped the fix guardrail.
- `REVIEW_ERROR phase=ci reason=limits_reached` now carries
  `limit_source=agent|hosted_ci`. For fix/CI-fix agent limits with `retry_after`
  more than 6 h away, `hive run` names `review.fix.agent` / `review.ci.agent` as
  the key for choosing another agent profile. This is text only; Hive does not
  switch agents automatically.
