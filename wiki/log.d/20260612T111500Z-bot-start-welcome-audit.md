---
date: 2026-06-12
slug: bot-start-welcome-audit
pages: [commands/bot, modules/bot, testing, gaps]
---

Post-commit bot command/module coverage audit after `4353734f`
(`feat(bot): /start replies with a welcome instead of a shrug`) added
`Router` intent `:slash_start`, `SlashHandlers#start`, and focused router /
slash-handler tests. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "telegram /start bot welcome hivebox bot supervision"` returned no
indexed hits, and the configured master wiki path had no matching context.

Inspected the committed diff plus current `lib/hive/bot/router.rb`,
`lib/hive/bot/handlers/slash_handlers.rb`, `lib/hive/bot/supervisor.rb`,
`test/unit/bot/router_test.rb`, `test/unit/bot/slash_handlers_test.rb`,
`test/unit/bot/supervisor_test.rb`, the committed `bot-start-welcome`
fragment, and the affected wiki pages. Updated [[commands/bot]] with the
supported `/start` behavior while keeping `setMyCommands` accurate: the
registered quick-actions menu still contains the nine typeable workflow
commands, and `/start` is handled separately for Telegram's automatic
first-contact update. Refreshed [[modules/bot]] for the new router/handler
surface, [[testing]] for the source-tree coverage, and [[gaps]] for the missing
live Bot API / Dockerized hivebox smoke evidence. Page coverage did not change,
so [[index]] required no catalog update. Verified the fragment with
`bundle exec ruby -Itest test/unit/wiki_log_test.rb`. Did not edit compiled
[[log]], run `qmd update`, or run `qmd embed`.
