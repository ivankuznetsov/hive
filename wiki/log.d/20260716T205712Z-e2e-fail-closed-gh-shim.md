---
title: Refresh fail-closed GitHub E2E shim coverage
date: 2026-07-16
tags: [wiki, e2e, github, testing]
---

- Refreshed [[e2e]] and [[testing]] for commit `b3820ae0`, which adds the
  E2E-only default-deny `gh` executable, ordered `script_gh` scenario DSL,
  environment-pinned run-local interaction ledger, exact argv/cwd/repository matching,
  scenario-end consumption verification, repro emission, and copied failure
  evidence.
- Recorded in [[gaps]] that the boundary is covered by focused harness tests,
  including real blocking/background `bin/hive` subprocess inheritance, but no
  checked-in scenario yet uses `script_gh` to drive a GitHub-dependent stage;
  tmux inheritance and an executed GitHub-bound repro remain source-pinned.
- Searched the configured main wiki and found no cross-project Hive E2E/GitHub
  shim guidance to merge. Page coverage did not change, so [[index]] was not
  edited. QMD was intentionally not run.
