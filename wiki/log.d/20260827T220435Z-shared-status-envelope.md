# 2026-08-27 — Extract bot status envelope compatibility

**Why:** The Telegram bot's long-running status subprocess consumer needs a
single strict envelope-shape, forward-version tolerance, older-version refusal,
and operator-guidance policy.

**Change:** Added `Hive::StatusEnvelope` and routed `StatusWatcher` through it
without changing row projection or warning delivery. The daemon retains its
in-process status producer, where subprocess schema skew is not a boundary.

**Verification:** The focused bot status-watcher suite covers exact, newer,
older, malformed, and `ok=false` envelopes.
