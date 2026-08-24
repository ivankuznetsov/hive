---
title: Retry structured OpenCode provider rate limits
date: 2026-08-24
tags: [opencode, provider-limit, retry, agent-cli-runtime]
---

OpenCode provider errors place their diagnostic under
`error.data.message`, outside the legacy top-level error shapes. The OpenCode
runtime profile now extracts that dedicated structured payload so a real
upstream rate-limit refusal is typed as `rate_limited`; Hive records its
canonical `limits_reached` marker and the daemon can retry after cooldown.
Extraction remains restricted to OpenCode `error` events, preventing ordinary
model prose from becoming provider-control evidence.

Focused component and Hive lifecycle tests cover the exact nested event shape,
typed result, skipped export, and retryable marker.
