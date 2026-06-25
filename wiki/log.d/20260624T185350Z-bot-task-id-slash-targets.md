---
date: 2026-06-24
slug: bot-task-id-slash-targets
pages: [commands/bot, modules/bot]
---

`/answer`, `/approve`, `/autofix`, and `/details` now accept the numeric task id
shown in Telegram notifications and `/status` rows, with or without a leading
`#`. Numeric targets resolve against the bot's current `StatusWatcher` snapshot
to the task slug before the existing action path runs, so archived or
scrolled-out ids stay untargetable and id misses report the normalized
`#id` (leading zeros stripped, e.g. `09281` → `#9281`), not the literal
typed string.

Updated [[commands/bot]] with the `<id|slug>` typeable command surface and
[[modules/bot]] with the split between slug-based callback payloads and
id-or-slug slash-command arguments.
