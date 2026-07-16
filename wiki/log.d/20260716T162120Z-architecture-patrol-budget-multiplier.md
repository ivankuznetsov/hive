---
title: Give architecture patrol a larger bounded cycle envelope
date: 2026-07-16
tags: [patrol, refactor-patrol, tokens, config, subscription]
---

- Added `patrol.architecture_budget_multiplier`, defaulting to `2`, for architecture review/fix cycle tokens, cycle launches, and the per-agent budget-equivalent guard.
- Kept the selected patrol tier's UTC-day token and launch ceilings shared across ordinary and architecture patrol.
- Clarified that `max_budget_usd_per_agent` follows agent CLI terminology and is a runaway kill switch for subscription-backed agents, not a separate Hive payment.
