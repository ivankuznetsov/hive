---
date: 2026-07-26
title: Task capture gained one supported end-to-end command
tags: [web, capture, worktree, artifacts, playwright]
---

- Added `hive web capture --task-folder ... --source-root ...` as the supported
  artifacts-stage recorder over the private capture-server lifecycle.
- Added a lockfile-keyed Playwright and Chromium cache outside linked
  worktrees, deterministic private fixture seeding, and retained PNG/WebM
  validation.
- Capture rechecks the exact clean source HEAD after teardown and publishes the
  task-local media and `hive-artifact-capture` manifest last.
