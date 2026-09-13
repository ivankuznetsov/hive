---
title: Preserve freshness while revised plans await decisions
date: 2026-09-13
---

Live decision-triage dogfood revealed that the transition guard treated every
candidate as already promoted. Writero and the lifecycle-ledger review retained
their original canonical bytes correctly, but status falsely demanded a linked
review. Pending reviews now accept original or candidate bytes without granting
execution. Cleared reviews still require the final candidate. Regression tests
use distinct revised content, exercise the actual orchestrator, and retain
reverted-plan rejection after clearance.

The same live records exposed interrupted verification being parked on a pending
manual choice. Recovery now finishes incorporated dispositions first, preserves
retry pacing, and exposes exhausted verification as a repair blocker. A failed
standard reviewer cannot take the degraded clearance fast path while manual
choices or verification targets remain.
