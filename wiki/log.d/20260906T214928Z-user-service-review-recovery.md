---
title: Close UserService recovery verification gaps
date: 2026-09-06
---

- Made uninstall stop before destructive cleanup when service removal is busy
  or retains ambiguous coordination evidence.
- Routed runtime cutover stop/start through the daemon, bot, and web
  UserService lifecycle owners and covered canonical-target contention.
- Replanned requested applies after unrelated recovery, reconciled running
  processes when promoting filesystem-only receipts, retained stop intent when
  manager observation is unavailable, and verified stopped-to-running restart
  plus rollback restoration with fresh process identity evidence.
- Strengthened the mandatory real-systemd teardown so emergency cleanup cannot
  hide a UserService removal failure or inconclusive manager/coordination state.
