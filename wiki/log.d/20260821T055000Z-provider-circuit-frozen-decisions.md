---
title: Keep provider circuit inspection read-only over frozen decisions
date: 2026-08-21T05:50:00Z
tags: [provider-routing, circuits, attempts, immutable]
---

`hive circuits` now filters the immutable Attempts decision-index snapshot into
a new array instead of calling `select!` on the frozen reader result. The bug
was invisible while no global provider account was configured; adding the
first explicit recovery route made the read-only inspection fail with
`FrozenError` before it could report circuit health. The focused projection
fixture now returns a frozen decision array to preserve the production
contract.
