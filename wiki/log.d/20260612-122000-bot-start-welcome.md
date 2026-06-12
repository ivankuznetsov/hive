---
date: 2026-06-12
slug: bot-start-welcome
pages: [commands/web, modules/bot]
---

Dogfood report: a freshly connected hivebox bot greeted its first /start —
the command Telegram sends automatically on first contact — with "I did
not understand that", and the operator saw "no menu and no commands". Two
causes: /start had no route (now → a welcome reply with concrete next
steps: /status, /idea, /help), and the command menu (setMyCommands at bot
boot) plus all replies require a running bot process — which the BOX
supervisor manages, but a dev-host bare `rails server` does not; noted in
[[commands/web]] that `hive bot start` is manual there.
