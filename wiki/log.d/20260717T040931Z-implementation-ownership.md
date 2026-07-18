---
title: Automatic generation-scoped implementation ownership
date: 2026-07-17
tags: [agents, identity, journal, execute, open-pr, review, status]
---

- Added immutable normalized provider/model/effort selections and provider-native argv translation for Claude, Codex, pi, and Grok.
- Captured concrete execute ownership in the authoritative task journal before spawn, with idempotent per-generation replay, legacy reconstruction/backfill, and retained history.
- Routed PR opening to provider-local utility/default models and review/CI repairs to the exact execute model, while preserving raw field-level overrides and independent reviewer/triage/browser identities.
- Exposed resolved and preview ownership through status JSON/text, the TUI `I` detail view, and Hivebox without turning reads into mutation boundaries.
- Added lifecycle, generation-drift, unsupported-effort, schema, launcher-envelope, and status-purity coverage; recorded native pi/grok config-schema drift as a known gap.
