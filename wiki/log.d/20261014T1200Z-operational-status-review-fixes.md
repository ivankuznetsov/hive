# 2026-10-14 — Read-only operational inspection review fixes

- Removed nested process-guard checkouts from mount confirmation, bounded full
  integrity validation to one pass per owned inspection session, and made all
  mutating database entrypoints reject that session before opening writable
  storage or acquiring a writer fence.
- Narrowed typed storage translation to the intended read-only and metadata
  errnos so custody, corruption, contention, descriptor exhaustion, and disk I/O
  retain their established handling. Mount ambiguity and unavailable metadata
  now remain fail-closed with diagnostic reasons.
- Strengthened CLI, WAL-only, unpaired-sidecar, fork-concurrency, workflow-lock,
  lifecycle-envelope, and real read-only mount coverage. The Docker gate accepts
  a paired-sidecar degraded result only with underlying SQLite recovery evidence.
