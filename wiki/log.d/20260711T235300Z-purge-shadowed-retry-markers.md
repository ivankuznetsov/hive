---
title: Purge shadowed markers during daemon retries
type: fix
date: 2026-07-11
---

Healer-managed marker clears now atomically remove shadowed marker history
after the current marker name and attributes pass their race guard. Repeated
generic workflow attempts can leave an older `AGENT_WORKING` plus terminal
errors beneath the current retryable error; clearing only the newest marker
made the daemon rediscover that dead history and wait through another stale
grace cycle instead of redispatching.

Manual `hive markers clear` remains a single-current-marker operation. New
marker and stale-healer regressions cover stacked working/error history while
proving that state-file prose remains intact.
