---
title: Keep each E2E Hive home private
type: fix
created: 2026-07-31
tags: [e2e, security, patrol, qualification]
---

- Create and explicitly reharden every scenario-owned `HIVE_HOME` to mode
  `0700` before writing its configuration.
- Pin the private-mode contract in the real Sandbox bootstrap test so a
  permissive local or hosted-runner umask cannot expose harness state.
- Unblock the Patrol qualification controller's fail-closed run-home
  admission without weakening its ownership or permission checks.
