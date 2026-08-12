---
title: Route admission uses one batched health snapshot
date: 2026-08-11T17:00:00Z
tags: [provider-health, provider-routing, admission, performance]
---

Added ordered batch route evaluation to Provider Health and switched Attempts
admission to it. A selection pass now acquires the host-global health lock
once, scans probe intents once, and replays each unique account/model scope
once instead of repeating that work for every candidate.
