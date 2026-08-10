---
title: Close daemon admission during signal shutdown
type: fix
created: 2026-07-30
tags: [daemon, scheduler, signals, shutdown, concurrency]
---

TERM and INT now close one daemon-wide admission predicate. It is rechecked
after blocking reconciliation and capacity work, between multi-candidate
loops, and at the final durable-attempt, lost-successor, display-name, and
supervised-child launch boundaries. Shutdown also releases request preclaims
and patrol/digest reservations that were acquired before the signal. Existing
accepted children still follow the normal bounded termination-and-drain
lifecycle.
