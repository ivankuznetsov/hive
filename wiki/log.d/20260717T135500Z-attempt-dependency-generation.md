---
title: Bind durable attempts to dependency admission
date: 2026-07-17
---

**Action:** Added the task's deterministic dependency-admission verdict to the
durable attempt progress token. Terminal receipts still replay for an unchanged
generation, but a prerequisite advancing from a blocking stage to the configured
gate now creates a fresh generation instead of replaying the earlier exit-75
dependency wait. The real incident-regression scenario pins the wait-to-clear
transition through the public CLI.
