---
title: Isolate the test suite from the operator Git config
type: fix
date: 2026-07-26
---

- Route every test subprocess through a disposable `GIT_CONFIG_GLOBAL` file.
- Prevent an outer `XDG_CONFIG_HOME` from letting `git config --global` tests
  rewrite the operator's credential helpers or other global Git controls.
- Cover the suite-level sandbox contract and clean it after the test process.
