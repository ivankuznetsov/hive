---
title: Share reviewer deadline policy
type: changed
date: 2026-07-18
---

`Hive::Reviewers::Base` now owns the monotonic remaining-time calculation and
per-spawn timeout clamp shared by the agent and native Codex review adapters.
Their configured timeouts, expired-deadline behavior, retry decisions, and
spawn interfaces are unchanged.
