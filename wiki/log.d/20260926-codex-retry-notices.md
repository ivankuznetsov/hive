# 2026-09-26 — Codex retry notices no longer mask the real provider error

- Codex emits each transport retry as an `error` event
  (`Reconnecting... 2/5 (stream disconnected ...)`) before the terminal error
  and `turn.failed`. Hive keeps the first provider error of a run, so a revoked
  Codex login surfaced as a retryable "websocket closed" disconnect: planner
  revisions and other Codex stages were scheduled for retry indefinitely with no
  hint that the operator had to log in again.
- The codex profile now uses a dedicated error extractor that skips retry
  notices, so the terminal failure (for example `unexpected status 401
  Unauthorized: Incorrect API key provided`) is the recorded provider error.
  The runtime also reads Codex's `unexpected status NNN` form as the status
  code, so Codex 402/429 failures classify as provider limits.
