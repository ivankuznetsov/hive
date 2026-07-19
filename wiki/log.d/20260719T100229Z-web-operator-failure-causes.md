---
title: Hive Web preserves operator failure causes
type: change
date: 2026-07-19
tags: [web, agents, init, errors]
---

- Managed agent-skill repair failures now show and log the command
  classification plus bounded failed-operation messages, residual health, or
  captured stderr instead of a fixed generic alert.
- The web adapter's health method no longer shadows Ruby's zero-argument
  `Object#inspect` contract.
- Repo registration and settings re-init now capture Init's non-interactive
  provisioning findings and render them as an alert alongside the successful
  setup notice.
