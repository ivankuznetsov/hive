---
title: Complete Telegram pairing in Hive Web
created: 2026-07-18T23:55:00Z
tags: [web, telegram, pairing, authentication]
---

- Allowed the Telegram form to bootstrap securely with pairing enabled and no
  pre-known chat ID, while continuing to reject an empty authorization boundary
  when pairing is off.
- Added pending-code visibility and explicit, owner-confirmed approval through
  the existing atomic Pairing command lifecycle.
- Allowed authorization settings to change without re-entering a previously
  validated bot token; replacement tokens still pass `getMe` before persistence.
- Added adapter and request coverage for list/approve delegation, empty-list
  bootstrap, saved-token reuse, consent enforcement, and disabled-mode laziness.
