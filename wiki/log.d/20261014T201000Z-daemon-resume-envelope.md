# 2026-10-14 — Daemon resume emits one JSON refusal

- Fixed the schema-skew `hive daemon resume --json` path to emit one lifecycle
  error envelope, allowing consumers to parse its migration guidance reliably.
