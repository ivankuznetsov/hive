---
title: Web pairing failures and workflow terminal state
type: change
date: 2026-07-19
tags: [web, telegram, pairing, workflows, daemon]
---

- Owner-facing pairing list reads now surface malformed or unreadable pairing
  state through the CLI error envelope and Hive Web alert instead of presenting
  a false empty list; bot-side recovery reads remain tolerant.
- The task daemon-paused banner now derives terminal directories from all
  registered workflow descriptors rather than assuming coding's `9-done`.
- Added web and unit regressions for corrupt pairing state, blank first-time
  tokens, expired approval errors, running-daemon suppression, and non-coding
  terminal tasks.
