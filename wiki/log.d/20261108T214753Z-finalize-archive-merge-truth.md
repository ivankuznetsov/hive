## 2026-11-08 — Archive requires a merged PR; finalize re-checks summary.md completion

- `hive archive <slug>` (ordinary path, no `--reason`) from `8-finalize` now
  asks GitHub via `Hive::Gh.pr_state` whether the `pr.md` PR is `MERGED`
  before the terminal move. An OPEN/CLOSED PR refuses with
  `Hive::ArchivePrNotMerged` (`reason=pr_not_merged`); a gh failure or a
  missing/non-canonical `pr_url` fails closed with
  `Hive::ArchivePrStateUnobservable` (`reason=pr_state_unobservable` /
  `pr_url_unresolved`). Both exit `4` (`WrongStage`), name the PR URL and
  state, and point at merging the PR or `--reason
  already_delivered|superseded|cancelled`. Explicit `--reason` closures are
  unchanged.
- `Stages::Finalize.run!` no longer treats `summary.md` alone as terminal.
  `completed_finalize_state` requires a canonical `pr_url`, recorded
  `head_oid`, a `COMPLETE is_draft=false` marker bound to that URL, and GitHub
  reporting the PR `MERGED` or OPEN/non-draft at the recorded head. Otherwise
  it prints the drift and re-runs the normal finalize path. The
  `already complete ((no url))` message is gone; the canonical URL is printed.
- Regressions: `test/integration/run_stage_action_test.rb` (OPEN refused,
  typed JSON envelope, MERGED archives, gh error fails closed, missing pr_url
  fails closed) and `test/integration/run_finalize_test.rb` (genuine
  completion still idempotent, draft PR re-readied, moved head re-recorded,
  cleared marker no longer claims completion, drift classification).
- Hive task: review-and-finalize-do-not-261108-6f72.
