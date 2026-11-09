## 2026-11-09 — SQLite busy/storage classification bounds its cause walk

- Symptom: `SQLiteSupport.busy_error?` hung a test while merging PR #1591.
- Cause: the private `caused_by?` helper (shared by `busy_error?` and
  `storage_exhaustion_error?`) followed `Exception#cause` with no depth bound
  or cycle detection, so a self-referencing or cyclic cause chain (A->B->A)
  looped forever.
- Fix: `caused_by?` now inspects at most `SQLiteSupport::MAX_CAUSE_DEPTH`
  (16) links and stops at the first exception already seen (identity hash).
  Classification of ordinary chains is unchanged.
- Other cause walks in `lib/` were already safe: `CommandOperation`
  `retryable_pre_submission_contention?` and `Hive::Error.sqlite_busy?` are
  bounded at 5 links; `RuntimeControlPlane::Database#error_chain` dedupes by
  `object_id`.
