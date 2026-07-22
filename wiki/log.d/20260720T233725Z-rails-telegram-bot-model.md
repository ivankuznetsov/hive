---
title: Move Telegram configuration into a Rails model
date: 2026-07-20
tags: [web, rails, architecture, telegram]
---

Hive Web now represents the configured bot as `TelegramBot`. The model owns
strict numeric allowlist parsing, saved-secret lookup and persistence, live
token validation, global configuration, supervisor reload signalling,
round-trip test delivery, pending pairing rows, and consent-gated approval.

`TelegramController` is reduced to the settings resource's `show` and `update`
actions. The established `/telegram/test` and `/telegram/pairings/:code` URLs
now create `Telegram::TestMessage` and `Telegram::PairingApproval` resources
through small namespaced controllers. The page consumes named model predicates
and typed pairing rows instead of configuration/pairing hashes.
