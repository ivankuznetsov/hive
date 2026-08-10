---
title: Fence repository patrol to coding workflows
date: 2026-08-10
---

- Ordinary Patrol and Architecture Patrol now require the registered project's
  resolved default workflow to be `coding`, regardless of stale enable flags.
- The daemon stops before repository inspection or merged-PR intake for
  non-coding defaults, and reservation-time checks prevent a workflow change
  from racing a queued dispatch.
- Manual execution is rejected for non-coding projects, while Architecture
  Patrol's read-only job queries and ordinary receipt-only recovery remain
  available.
- Agent skill provisioning no longer includes Patrol reviewers for a
  non-coding project.
