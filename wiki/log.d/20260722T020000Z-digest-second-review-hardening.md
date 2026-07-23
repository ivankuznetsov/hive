## 2026-07-22 — Hardened digest evidence and trust boundaries

- Made merged-PR page traversal require stable consecutive snapshots, preserved valid UTF-8 transport text, and accepted independently quoted Git rename paths.
- Kept redacted PR bodies and diffs file-backed through generation, with direct-to-file diff capture and cleanup on every orchestration exit.
- Moved digest runtime policy outside the writable agent root, delete that root wholesale after each invocation, canonicalized secret-shaped fact IDs, and added a verified Telegram-boundary redaction pass.
- Rejected the removed `digest.source` key, qualified private repository identities by GitHub host, and strengthened London-transition, forbidden-Hive-read, host-collision, and implementation/fix/release/migration coverage.
