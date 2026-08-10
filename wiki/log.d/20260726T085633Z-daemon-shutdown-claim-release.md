---
title: Graceful daemon shutdown releases ancillary claims
type: log
created: 2026-07-26
---

The ancillary `ChildSupervisor` now returns exits reaped while draining
children during daemon shutdown. The dispatcher routes those exits through the
same completion method used during normal ticks before closing its logger.

This reuses the current scheduler lifecycle rather than adding another recovery
mechanism. Before signalling, the supervisor captures and confirms the full
descendant tree plus the original process group. It escalates captured
survivors through KILL and returns the direct-child exit only after both fences
are proven dead. If tree identity is unavailable or a descendant survives, the
exit is withheld and the current lease stays fenced.

A safely terminated architecture-patrol child releases its existing
generation-fenced v2 discovery claim with normal retry backoff; digest,
controller, ordinary-patrol, and queued-request hooks receive the same truthful
exit. Signal-derived nil exits now record terminal recovery and ordinary patrol
as failed rather than raising or clearing failure backoff.

Focused supervisor, dispatcher, and patrol-scheduler regressions cover nested
TERM-ignoring descendants, unverifiable tree fencing, returned signal exits,
terminal-recovery failure receipts, ordinary-patrol backoff, and
architecture-patrol retry completion.
