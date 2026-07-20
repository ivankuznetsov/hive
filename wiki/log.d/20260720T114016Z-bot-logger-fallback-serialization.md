---
title: Serialize bot logger fallback writes
type: fix
date: 2026-07-20
tags: [bot, logging, concurrency, errors]
---

- Serialized bot log rotation, fallback-state transitions, and file writes so
  the supervisor's shared logger cannot race across its worker threads.
- If rotation and the recovery reopen both fail, the in-flight JSON line and
  future log lines fall back to stderr instead of raising on a missing file
  handle.
