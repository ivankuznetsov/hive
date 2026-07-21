---
title: hive pairing
type: command
source: lib/hive/cli.rb, lib/hive/commands/pairing.rb, lib/hive/bot/pairing_store.rb, lib/hive/bot/pairing_approval_queue.rb, lib/hive/web/telegram_pairing.rb, web/app/controllers/telegram_controller.rb
created: 2026-06-30
updated: 2026-07-19
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
  `--json` it emits `hive-pairing-list.v1`. Owner-facing list reads are strict:
  malformed JSON and permission/read failures return `store_read_failed`
  instead of rendering the store as an empty pending set. Bot-side mint,
  resolve, and consume operations retain their tolerant fallback so a damaged
  pending file cannot wedge first-contact recovery.
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

## Web surface

Hive Web's Telegram settings can enable pairing with an empty manual allowlist,
which makes first-contact setup possible without copying a numeric ID from a
separate bot. Once enabled, `/telegram` reads pending entries through the same
`hive-pairing-list.v1` producer and exposes the code, chat ID, age, and expiry.
Approval is an owner-gated, CSRF-protected POST with an explicit consent marker;
it calls the same `Commands::Pairing approve telegram <CODE>` transaction rather
than duplicating allowlist or code-consumption logic in Rails. A failed approval
therefore leaves the code retryable under the CLI contract, while a success
reports whether the running bot reloaded or needs a restart.
If the pending store is unreadable, the page renders that command error in the
pairing panel; it never substitutes "No pending pairing requests."

## Related

- [[commands/bot]]
- [[modules/bot]]
- [[modules/config]]
