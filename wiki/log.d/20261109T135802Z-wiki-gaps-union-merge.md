## 2026-11-09 — `wiki/gaps.md` merges with the union driver

`.gitattributes` sets `merge=union` for `wiki/gaps.md`. Concurrent PRs each
append gap sections, and every merge to main left the other open PRs
conflicting only in this file (Hive tasks parked at `REVIEW_CI_STALE
reason=base_conflict`). Local merges and Hive's review-stage rebase now keep
both sides automatically.
