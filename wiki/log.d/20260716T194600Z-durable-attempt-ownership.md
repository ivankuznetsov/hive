---
title: Durable task-stage attempt ownership
date: 2026-07-16
tags: [attempts, daemon, recovery, e2e]
---

- Unified CLI, workflow actions, queued bot/web delivery, daemon auto-advance,
  and loss successors behind generation-idempotent durable admission.
- Added detached wrappers, guarded lease/receipt records, framed logs,
  restart adoption, lease-first capacity, and conservative legacy backfill.
- Added verified orphan cleanup, mutation-free dirty capture, one durable
  `attempt_lost` outcome, and bounded same-generation successors.
- Added the YAML 1849 replay proving three commits survive temporary caller
  termination and finish from one wrapper receipt without a daemon.
