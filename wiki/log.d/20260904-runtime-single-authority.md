---
title: Finish runtime table cuts and remove shadow attempt records
date: 2026-09-04
---

- Reduced the runtime schema from fourteen to ten tables (including Sequel's
  schema metadata). Folded the task counter into installations; kept token usage.
- Removed Patrol failure cohorts and probe accounting. Automatic retry pacing
  derives from the latest final attempt for the same task/generation/runtime.
- Removed both PR merge tables and their repository. Current task PR metadata,
  GitHub evidence and existing task closure receipts own reconciliation. Restart
  re-observes and safely retries intake/closure; fair polling state is disposable.
  Historical same-generation PR drift is no longer remembered by a separate ledger.
- Removed attempts.record_json and record_digest. SQL owns indexed identity and
  lifecycle fields; JSON stores non-overlapping execution details, subject and
  terminal receipt. Lease-version CAS, accounting, publication acknowledgements
  and lost-recovery revision remain independent and restart-safe.
- Rewrote the unreleased bootstrap schema in place. No live database or dogfood
  deployment was changed. Existing SQLite installations need a separately
  implemented, token-preserving schema cutover; `hive migrate --all` does not
  implement this replacement.
- Final focused runtime verification: 450 tests passed; changed Ruby files lint
  clean. The 13,921-test main sweep found one usage fixture without canonical
  task identity; corrected it and reran its 12-test integration file successfully.
  The standard rake prerequisite stopped on an unrelated unavailable OpenCode
  offline-smoke route; no local coverage or live-provider gate is claimed.
