---
title: Load the babysitter one-shot adapter at command initialization
date: 2026-09-28
---

`Hive::Commands::Babysit` now loads its one-shot adapter with the command,
keeping direct `--once` adapter construction aligned with `run_once` and its
persistent-admission check.
