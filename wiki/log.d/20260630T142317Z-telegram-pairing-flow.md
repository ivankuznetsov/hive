## 2026-06-30 — Telegram pairing flow

- Added `bot.pairing_enabled` and the `hive pairing` owner command so unknown Telegram DM users can request access with `/start`, receive a short-lived pairing code, and be approved into `bot.chat_id_allowlist` without hand-editing config.
- Added file-backed pairing state under `~/.local/state/hive/.bot.pairings.json` and a separate `pairing_approvals/` notice queue drained by the bot reaper for the proactive approved DM.
- Updated digest behavior to mention pending pairing requests and documented the new CLI, bot, config, state, operating, and testing surfaces in the wiki.
