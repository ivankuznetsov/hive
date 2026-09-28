---
title: Load babysitter one-shot adapter at its construction boundary
date: 2026-09-28
---

`Hive::Commands::Babysit#one_shot_adapter` now requires its adapter immediately
before constructing it. This keeps direct adapter use independent of a prior
`run_once` call and prevents coverage-shard load-order failures.
