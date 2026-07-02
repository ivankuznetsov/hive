---
title: hive pairing
type: command
source: lib/hive/cli.rb, lib/hive/commands/pairing.rb, lib/hive/bot/pairing_store.rb, lib/hive/bot/pairing_approval_queue.rb
created: 2026-06-30
updated: 2026-06-30
tags: [command, bot, telegram, pairing, json]
---

**TLDR**: `hive pairing` is the owner-side approval surface for Telegram bot
first-contact pairing. Unknown DM chats can send `/start` when
`bot.pairing_enabled: true`; the bot returns a one-time code, and the owner
runs `hive pairing approve telegram <CODE>` to append that chat id to the
global bot allowlist.

## Synopsis

```bash
hive pairing list [--json]
hive pairing approve telegram <CODE> [--json]
```

`telegram` is a fixed literal, not a platform registry.

## Behavior

- Pending requests live in `~/.local/state/hive/.bot.pairings.json` as
  `code -> {chat_id, created_at}` with 8-character `A-Z` codes and 24-hour
  expiry.
- `list` prints pending code, chat id, creation time, age, and expiry; with
  `--json` it emits `hive-pairing-list.v1`.
- `approve telegram <CODE>` consumes an unexpired code, validates the current
  global bot config, appends the chat id to `bot.chat_id_allowlist` through
  `Config.update_global_config!`, sends `SIGHUP` to the running bot when a live
  bot PID file exists, and writes a `hive-pairing-approval` notice for the bot
  to DM the newly approved chat.
- Unknown or expired codes fail without mutating `config.yml` or writing an
  approval notice. Invalid argument shapes fail as usage errors.

The approval notice queue is a separate owner-only
`<state_home>/pairing_approvals/` directory, not an extension of the daemon
dispatch-result schema. The bot reaper drains it and removes notices only after
Telegram send succeeds; stale notices are dropped after one hour. It does not
re-check the in-memory allowlist before sending the "approved" DM, because the
config write and SIGHUP reload are asynchronous.

## Related

- [[commands/bot]]
- [[modules/bot]]
- [[modules/config]]
