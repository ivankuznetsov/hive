---
title: Self-contained built-in benchmark runtime
type: change
date: 2026-07-13
---

- `hive init --workflow bench` now snapshots the packaged benchmark harness,
  runner image, and campaign example into `.hive-state/bench-runtime` and
  commits them on `hive/state`.
- Packaged bench stage scripts resolve their executable runtime from that
  state snapshot while keeping `corpus/` and `runs/` in the benchmark project.
- A fresh benchmark project no longer requires a separate hive-bench checkout;
  the public repository remains the evidence, contribution, and methodology
  home.
