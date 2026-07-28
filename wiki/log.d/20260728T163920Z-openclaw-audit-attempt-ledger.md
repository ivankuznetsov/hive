## 2026-07-28: Make OpenClaw command audit crash-safe

**Action:** Replaced the generated single-row audit-gateway script with a thin
installer plus a committed six-file runtime. The launcher verifies the exact
copied runtime and immutable config digests before loading code. A strict
schema-v2 attempt ledger now fsyncs an `attempted` row before admission checks
or candidate launch and appends a same-ID `terminal` row for every ordinary
success, denial, or failure. Pending, malformed, duplicate, mismatched,
denied, or failed history fails closed before another candidate launch; command
ordinals derive from completed pairs rather than physical line count. Result
rows carry and verify the successful attempt ID through a separate bounded,
no-follow reader. Deterministic attempt IDs detect corruption, truncation, and
broken pairing; they are not authenticity evidence against coherent same-UID
rewriting. A separate bounded task binder requires ordinal 6 `created=true` and
one symlink-free metadata path matching the slug, workflow, and idempotency key
before ordinal 7 can launch.

**Evidence:** Focused tests cover nine successful pairs/18 rows, denial and
failure pairs, a real candidate side effect followed by parent SIGKILL and a
non-reexecuting poisoned retry, malformed/duplicate/mismatched history,
write/fsync failures, exact runtime copies, runtime/config link or digest
drift, stale/wrong-workflow/wrong-key/wrong-result run admission, malformed/
extra/reordered/type-invalid/symlink/oversize result ledgers, symlinked/
oversize/duplicate task metadata, serialization, and credential isolation. The
deterministic fake proof remains direct native-tool-surface
evidence and does not claim a live model loop.
