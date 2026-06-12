---
date: 2026-06-11
slug: telegram-setup-guide
pages: [commands/web]
---

The Telegram page gained a first-timer setup guide (collapsible, open
while the bot is unconfigured): create the bot via @BotFather /newbot,
get the numeric chat ID by messaging @userinfobot (the mother-grade
version of README's curl+ruby getUpdates recipe), and /start the bot
before the round-trip test. Notes the no-webhook/long-polling model and
the /revoke rotation path. Shared .setup-guide/.setup-steps styles for
future agent-page guides.
