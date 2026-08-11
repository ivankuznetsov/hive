---
title: Ground provider errors in real subscription captures
date: 2026-08-11T11:35:00Z
tags: [provider-health, provider-routing, agent-profiles, provenance]
---

Provider-health transport normalization is now grounded in sanitized real CLI
captures instead of invented adapter envelopes. Claude's rejected
`rate_limit_event` for the `five_hour` and `seven_day` subscription windows is
the only enabled transport shape; its admitted launch binding supplies the
provider-account scope and it normalizes to `account_quota` without retaining
raw message content.

Real Codex and Grok failures expose only message text, and Pi has no reviewed
subscription-backed capture on the evidence host. Those adapters remain
task-local. The provenance inventory records the supported boundary and the
remaining gap, and the fallback incident now exercises the captured Claude
shape before selecting the next configured route.
