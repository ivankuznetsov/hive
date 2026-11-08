# 2026-09-26 — Attempt supervisors tolerate lock contention beyond the lease window

- The first lock-contention fix bounded busy retries by the 30s lease window.
  On a heavily swapping host (18.8 GB swapped on 15 GB RAM, I/O pressure
  `full avg10=40%`) the daemon and supervisors held the runtime database's
  write lock for 17–20s per transaction, so busy retries still ran out and four
  concurrent attempts were lost together at the same moment.
- Busy retries now use a separate `busy_tolerance_sec` (default 600s, never
  below `stale_sec`). This is safe past the lease window: the reconciler only
  marks an attempt lost when its owner process is gone or mismatched; a stale
  owner that still matches stays a capacity-reserving suspect, and any other
  lease holder surfaces as a lost compare-and-swap, which still ends the
  attempt at once.
