### 2026-06-14 — Daily shipped digest

- Added `Hive::Digest`, `hive digest`, and `Hive::Daemon::DigestScheduler` for
  a local-midnight daily Telegram shipped digest across registered projects.
- Added first-class digest config defaults/validation
  (`digest.*`, `budget_usd.digest`, `timeout_sec.digest`, `bot.digest_chat_id`)
  plus deterministic unit coverage and an opt-in live agent + Telegram e2e.
