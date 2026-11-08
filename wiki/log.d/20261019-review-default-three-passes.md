## 2026-10-19 — Default review to three fix passes

- Raised the `review.max_passes` default from 2 to 3 in `Config::DEFAULTS`,
  the `hive init` project template and the review-stage fallback.
- Large changes routinely surface new accepted findings on the verify pass
  after the second fix, stopping at `REVIEW_STALE reason=final_fix_unverified`
  for a hand fix. A third fix pass lets those findings be fixed automatically;
  the pass after the final fix stays verify-only.
- Explicit per-project `review.max_passes` overrides are unchanged.
