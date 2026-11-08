# 2026-10-03 — Recovery history outlives its delivered result

- `DispatchRepository#prune_results` deleted every completed request one hour
  after its result was delivered (`RESULT_RETENTION_SEC`), recovery requests
  included. Those rows are also the task's failure history: the retry ladder
  and identical-failure count read the latest terminal recovery. So each
  series reset after an hour, and a slow deterministic loop (hivedev F2's red
  review CI) never parked.
- For recovery rows, `prune_results` now clears only the result payload. The
  row then ages out under `TERMINAL_RECOVERY_RETENTION_SEC` (7 days) like any
  terminal recovery. Other rows are still deleted.
