---
title: Share patrol review error details
type: changed
date: 2026-07-18
---

Ordinary patrol and architecture patrol reviewers now use
`Hive::Patrol::ReviewErrorDetails` to persist the same agent
resource-exhaustion envelope. Their failure detection, messages, state writes,
and domain-specific review records remain separate.
