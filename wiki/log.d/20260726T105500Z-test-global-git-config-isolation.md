---
title: Isolate the test suite from the operator environment
type: fix
date: 2026-07-26
---

- Route every normal test subprocess through a disposable home before Hive
  loads, while deleting inherited Hive, XDG, agent, GitHub, and Git global-path
  overrides. Defaults keep following `HOME` when a test swaps it, and Git
  global files remain disposable without exposing the babysitter-sensitive
  `GIT_CONFIG_GLOBAL` override.
- Prevent old-code tests from recreating `attempts/v1`, managed setup tests from
  rewriting real agent skills, and Git tests from changing operator controls.
- Keep authenticated smoke tests as an explicit real-user-environment opt-out.
- Cover the suite-level sandbox contract and clean it after the test process.
