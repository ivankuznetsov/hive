---
title: Expose OpenCode across Hive roles and attribution
date: 2026-08-12
tags: [agent, opencode, routing, skills, usage]
---

**Change:** Registered OpenCode as an opt-in Hive backend across every
agent-bearing role without changing global, stage, council, or fallback
defaults. Exact nested routes and variants use the ordinary model-routing
surface, while an explicitly selected overlay config may supply its exact
default route.

**Readiness:** Added OpenCode canonical Hive-skill projection, project/user and
plugin skill discovery, pinned Compound Engineering `3.21.4` setup, shadow
detection, auth/status exposure, and agent-skill subprocess environment
isolation. Skill-dependent roles fail before spawn when their expected native
source does not resolve.

**Attribution:** Execute, open-PR, review-fix, and review-CI attempts append
observed requested/actual route, outcome, and nullable usage evidence without
overwriting the persisted requested implementation identity. SQLite, JSON
status, schemas, and the TUI now recognize OpenCode and preserve unavailable
separately from zero.
