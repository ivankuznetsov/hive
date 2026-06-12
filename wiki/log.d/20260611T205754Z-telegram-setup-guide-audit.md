---
date: 2026-06-11
slug: telegram-setup-guide-audit
pages: [commands/web, gaps]
---

Post-commit command/API coverage audit for `b47f6627`
(`feat(hivebox): first-timer setup guide on the Telegram page`). Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent compiled [[log]] entries first. `qmd search "hivebox telegram setup
guide bot token chat id"` returned no indexed hits, and the configured master
wiki only had generic Telegram gem references.

Inspected the committed diff plus current
`web/app/views/telegram/show.html.erb`,
`web/app/assets/stylesheets/application.css`,
`web/app/controllers/telegram_controller.rb`,
`web/test/integration/telegram_test.rb`, [[commands/web]], and [[gaps]].
Confirmed the Rails page now renders a collapsible first-timer guide that
starts open while `bot.enabled` is false, links BotFather and userinfobot,
walks bot creation, numeric chat ID lookup, `/start` before test messages,
long-polling/no-webhook setup, and `/revoke` token rotation. Updated
[[commands/web]] for the surface and integration-test contract, and updated
[[gaps]] to carry the new source-test evidence while keeping the missing
browser/Docker/live-agent smoke uncertainty. Page coverage did not change, so
[[index]] was not edited. Did not run tests, `qmd update`, or `qmd embed`.
