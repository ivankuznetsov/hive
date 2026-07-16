---
title: Bound patrol tokens and unmetered launches by tier
date: 2026-07-16
tags: [patrol, refactor-patrol, tokens, config, observability]
---

- Added low/medium/high/ultrapatrol token, agent-launch, and per-agent dollar ceilings for each cycle and UTC day.
- Shared the project budget across ordinary review/fix and architecture review/fix spawns.
- Included `refactor-patrol-*` rows in patrol usage aggregates and recorded missing token payloads as explicit unmetered launches.
- Simplified durable publication recovery by reusing one receipt constructor and loading an exact receipted patch directly.
- Reused the canonical PR-manifest JSON encoder for architecture proof digests.
