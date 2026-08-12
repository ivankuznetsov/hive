---
title: Add bounded corrupt probe-intent repair
date: 2026-08-11T12:00:00Z
tags: [provider-health, probes, circuits, recovery, audit]
---

Provider-health now inspects corrupt global probe-intent artifacts separately
from scoped circuit journals. Routing remains fail-closed because malformed
intent ownership cannot be attributed safely, while `hive circuits` exposes a
bounded opaque file token, digest, and protected reference.

The approved `reset-intent` action revalidates the exact artifact under the
health lock, refuses stale or valid state, writes the bytes and an audit
receipt to owner-private quarantine, and only then removes the source. This
restores routing without silently deleting possible ownership or mutating any
circuit, attempt, retry, or task state.
