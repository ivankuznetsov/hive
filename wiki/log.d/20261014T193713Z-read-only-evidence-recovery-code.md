# 2026-10-14 — Read-only evidence requires SQLite recovery code

- Tightened the real-mount AE4 degraded-outcome gate to accept only SQLite's
  recovery-specific extended result code and reject a generic SQLite read-only
  failure.
- Retained the full degraded payload and stderr in each affected command result
  so the uploaded evidence artifact carries the underlying failure.
