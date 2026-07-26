---
title: Graceful daemon shutdown releases ancillary claims
type: log
created: 2026-07-26
---

The ancillary `ChildSupervisor` now returns exits reaped while draining
children during daemon shutdown. The dispatcher routes those exits through the
same completion method used during normal ticks before closing its logger.

This reuses the current scheduler lifecycle rather than adding another recovery
mechanism. A signal-terminated architecture-patrol child releases its existing
generation-fenced v2 discovery claim with normal retry backoff; ordinary patrol,
digest, controller, and queued-request completion hooks receive the same
truthful exit. Children that cannot be reaped keep their existing lease fence,
preventing a replacement from overlapping a possibly live process.

Focused supervisor and dispatcher regressions cover returned signal exits and
shutdown routing into architecture-patrol retry completion.
