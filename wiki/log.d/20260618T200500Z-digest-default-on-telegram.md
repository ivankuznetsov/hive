## [2026-06-18T20:05:00Z] digest — default ON when Telegram bot is configured; drop `bot.digest_chat_id`

**Action:** Made the daily shipped digest opt-out instead of opt-in, and removed
the separate `bot.digest_chat_id` setting.

- `Hive::Config.load_global_digest_block` now derives `digest.enabled` from the
  bot config when the operator has not pinned it: `true` when `bot.enabled ==
  true` and `bot.chat_id_allowlist` has at least one integer chat, else `false`.
  An explicit `digest.enabled` (true or false) is always honored — only the
  unset case is derived (`override.key?("enabled")` gate). New private predicate
  `Config.telegram_digest_default?(data)`. Both scheduler-config callers
  (`Commands::Daemon#start_daemon`, dispatcher SIGHUP reconfigure) load through
  this method, so no second code path.
- Removed `bot.digest_chat_id`: gone from `DEFAULTS["bot"]`, validator
  `validate_bot_digest_chat_id!` deleted, removed from `templates/hive_config.yml.erb`
  and the `schemas/hive-digest.v1.json` description. `Digest::Sender.resolve_chat_id`
  now resolves to `bot.chat_id_allowlist[0]` only and raises
  `"bot.chat_id_allowlist[0] must be configured before sending digest"` when absent.
- Tests: new `load_global_digest_block` cases for auto-enable derivation
  (bot-configured → on; explicit false honored; no chat / disabled bot → off);
  `digest/sender_test` resolves via the allowlist; removed the
  `digest_chat_id` validation test; updated the digest e2e fixture.

Documented as [[decisions]] ADR-030. Refreshed [[commands/digest]],
[[modules/digest]], [[modules/config]], [[commands/bot]], and [[commands/daemon]].

**Refreshed pages:**
- [[decisions]]
- [[commands/digest]]
- [[modules/digest]]
- [[modules/config]]
- [[commands/bot]]
- [[commands/daemon]]
