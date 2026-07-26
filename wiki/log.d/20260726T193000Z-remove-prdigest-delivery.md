## 2026-07-26 — Remove Hive's PRDigest delivery adapter

- Removed `hive digest`, the PRDigest adapter, the daily merged-PR scheduler,
  its cursor/result handling, and the `prdigest` runtime dependency.
- Hive now rejects stale global `digest:` configuration when the daemon starts
  and points operators to standalone `prdigest prose --deliver` or agent-owned
  `prdigest facts`.
- Kept the unrelated `hive answer-digest` command and its host-local scheduler.
