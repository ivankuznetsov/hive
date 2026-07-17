---
title: Isolate wiki refreshes and bound patrol signal cost
date: 2026-07-16
tags: [llm-wiki, patrol, refactor-patrol, tokens, findings]
---

- Post-commit LLM-wiki refreshes now queue source commits in the shared Git directory and commit wiki-only updates on a local `llm-wiki/refresh` branch through a disposable managed worktree; user checkouts, logs, and QMD caches are no longer refresh outputs. Atomic source receipt refs make changed and no-op crash replay idempotent, and an ownership-checked compare-and-swap Git ref prevents stale-lock reclaimer races.
- Every ordinary patrol review/fix launch receives a tier-specific in-flight token cap; architecture launches receive the configured larger token allowance without multiplying the subscription provider's native dollar-equivalent guard. A project-wide agent-lifetime lock prevents concurrent workers from double-spending shared daily headroom.
- Claude message-start/delta usage now stops a process group at the smallest of its per-agent and remaining cycle/day ceilings, escalates TERM-resistant children to KILL, and all four ordinary/architecture launch paths record the resulting resource exhaustion.
- Architecture discovery skips slices that cannot mathematically reach the leverage floor, defaults to one thesis per feature, requires evidence of a current consequence, and retains any residual below-floor thesis as an audited suppression instead of a ranked finding.
- Ordinary and legacy architecture reports retain structured token-exhaustion evidence; legacy architecture output now marks partial review progress explicitly instead of presenting an interrupted run as a clean zero-finding result.
