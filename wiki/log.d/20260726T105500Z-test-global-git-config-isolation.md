---
title: Isolate the test suite from the operator environment
type: fix
date: 2026-07-26
---

- Route every normal test subprocess through disposable home, Hive, XDG, agent,
  GitHub, and global Git configuration roots.
- Prevent old-code tests from recreating `attempts/v1`, managed setup tests from
  rewriting real agent skills, and Git tests from changing operator controls.
- Keep authenticated smoke tests as an explicit real-user-environment opt-out.
- Cover the suite-level sandbox contract and clean it after the test process.
