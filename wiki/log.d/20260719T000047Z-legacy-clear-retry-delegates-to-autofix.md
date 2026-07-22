---
title: Delegate legacy clear-retry callbacks to Autofix
type: changed
date: 2026-07-19
---

Telegram buttons carrying the legacy `clear_retry` callback now delegate
directly to the current Autofix handler instead of duplicating its parser and
`RecoverySequence` call. Callback compatibility, marker matching, manual-only
refusals, workflow selection, keyboard clearing, and dispatches are unchanged.
