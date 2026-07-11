---
title: Babysitter dry-run wrappers use a private overlay
date: 2026-07-11
---

**Action:** Moved `Hive::Babysitter::DryRunEnv`'s generated `git` / `gh`
wrapper overlay out of the untrusted PR worktree and into a private temporary
directory. Wrapper creation now uses exclusive no-follow opens, and cleanup
removes only the exact generated overlay.

**Coverage:** Added a regression proving a tracked
`.hive-babysitter-dry-run-bin` symlink remains untouched and cannot redirect
wrapper writes outside the worktree.
