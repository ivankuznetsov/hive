---
title: Fail closed when provider health cannot open
date: 2026-08-11T11:45:00Z
tags: [attempts, provider-health, provider-routing, admission]
---

Explicit route admission now treats provider-health store construction and
preselection reconciliation as one fail-closed boundary. An unavailable or
unsafe health root produces and persists an operator-owned
`health_state_unavailable` no-route decision and starts no attempt. The legacy
path still bypasses provider-health construction entirely.
